// Extracted from TerminalController.swift (nuclear-review TC3): the v2 browser-automation surface (~3,700 lines) shares no logic with terminal/surface/workspace handling.
import AppKit
import Carbon.HIToolbox
import Darwin
@preconcurrency import Foundation
import Bonsplit
import os
import WebKit

extension TerminalController {
    // MARK: - V2 Browser Methods

    static let v2BrowserSnapshotRawEntryLimit = 4_096
    static let v2BrowserSnapshotTextInspectionLimit = 1_048_832

    enum V2BrowserSnapshotCollectionOutcome {
        case collected([String: Any])
        case frameUnavailable(String)
        case failed(String)
    }

    enum V2BrowserGeneratedSelectorAction {
        case click
    }

    enum V2BrowserGeneratedSelectorActionOutcome {
        case succeeded
        case frameUnavailable(String)
        case elementNotFound
        case failed(String)
    }

    enum V2BrowserFrameSelectorSource {
        case frameSelect
        case stateLoad
    }

    enum V2BrowserFrameSelectorApplyResult {
        case applied
        case rejected(limit: Int)
    }

    struct V2BrowserStateRestoreLimits {
        let documentByteLimit: Int
        let urlByteLimit: Int
        let cookieCountLimit: Int
        let storageEntryCountLimit: Int
        let storageKeyByteLimit: Int
        let storageValueByteLimit: Int
        let frameSelectorByteLimit: Int

        static let standard = V2BrowserStateRestoreLimits(
            documentByteLimit: 8 * 1_024 * 1_024,
            urlByteLimit: 16 * 1_024,
            cookieCountLimit: 1_024,
            storageEntryCountLimit: 4_096,
            storageKeyByteLimit: 4 * 1_024,
            storageValueByteLimit: 1_024 * 1_024,
            frameSelectorByteLimit: 16 * 1_024
        )
    }

    enum V2BrowserStateStepOutcome {
        case succeeded
        case timedOut
        case failed(message: String)
        case originMismatch(message: String)
        case unavailable(message: String)
    }

    struct V2BrowserStateNavigationMilestone {
        let navigationID: UUID
        let url: URL
        let executionURL: URL

        init(navigationID: UUID, url: URL, executionURL: URL? = nil) {
            self.navigationID = navigationID
            self.url = url
            self.executionURL = executionURL ?? url
        }
    }

    enum V2BrowserStateNavigationOutcome {
        case finished(
            committed: V2BrowserStateNavigationMilestone,
            finished: V2BrowserStateNavigationMilestone
        )
        case cancelled
        case timedOut
        case failed(message: String)
        case permissionDenied
        case unavailable
        case busy
    }

    struct V2BrowserStateStoragePayload {
        let expectedOrigin: String
        let executionOrigin: String
        let local: [String: String]
        let session: [String: String]
    }

    struct V2BrowserStateRestoreOperations {
        let installCookies: ([HTTPCookie], URL) -> V2BrowserStateStepOutcome
        let navigateAndWait: (URL) -> V2BrowserStateNavigationOutcome
        let applyStorage: (V2BrowserStateStoragePayload) -> V2BrowserStateStepOutcome
        let applyFrameSelector: (String?) -> V2BrowserStateStepOutcome
        let leaseIsValid: () -> Bool
        let cancelNavigation: () -> Void
    }

    final class V2BrowserStateRestoreLeaseCoordinator {
        enum DataStoreLeaseState: String, Equatable {
            case available
            case activeRestore = "active_restore"
            /// WebKit has accepted a mutation whose callback has not drained. This remains
            /// fail-closed, potentially until process restart, because releasing without the
            /// callback would let a late mutation overlap a newer restore.
            case taintedByUndrainedMutationCallbacks = "tainted_by_undrained_mutation_callbacks"
        }

        struct Lease {
            fileprivate let token: UUID
            fileprivate let dataStoreID: ObjectIdentifier
            fileprivate let generation: UUID
        }

        private struct ActiveLease {
            let lease: Lease
            var pendingMutationCount = 0
            var releaseRequested = false
        }

        static let shared = V2BrowserStateRestoreLeaseCoordinator()

        private let lock = NSLock()
        private var activeLeases: [ObjectIdentifier: ActiveLease] = [:]

        func acquire(dataStoreID: ObjectIdentifier, generation: UUID) -> Lease? {
            lock.lock()
            defer { lock.unlock() }
            guard activeLeases[dataStoreID] == nil else { return nil }
            let lease = Lease(token: UUID(), dataStoreID: dataStoreID, generation: generation)
            activeLeases[dataStoreID] = ActiveLease(lease: lease)
            return lease
        }

        func state(dataStoreID: ObjectIdentifier) -> DataStoreLeaseState {
            lock.lock()
            defer { lock.unlock() }
            guard let active = activeLeases[dataStoreID] else { return .available }
            return active.releaseRequested
                ? .taintedByUndrainedMutationCallbacks
                : .activeRestore
        }

        func isValid(_ lease: Lease, currentGeneration: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard currentGeneration == lease.generation,
                  let active = activeLeases[lease.dataStoreID] else { return false }
            return active.lease.token == lease.token && !active.releaseRequested
        }

        func beginPendingMutation(_ lease: Lease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var active = activeLeases[lease.dataStoreID],
                  active.lease.token == lease.token,
                  !active.releaseRequested else { return false }
            active.pendingMutationCount += 1
            activeLeases[lease.dataStoreID] = active
            return true
        }

        @discardableResult
        func endPendingMutation(_ lease: Lease) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var active = activeLeases[lease.dataStoreID],
                  active.lease.token == lease.token,
                  active.pendingMutationCount > 0 else { return false }
            active.pendingMutationCount -= 1
            if active.pendingMutationCount == 0, active.releaseRequested {
                activeLeases.removeValue(forKey: lease.dataStoreID)
            } else {
                activeLeases[lease.dataStoreID] = active
            }
            return true
        }

        func release(_ lease: Lease) {
            lock.lock()
            defer { lock.unlock() }
            guard var active = activeLeases[lease.dataStoreID],
                  active.lease.token == lease.token else { return }
            if active.pendingMutationCount == 0 {
                activeLeases.removeValue(forKey: lease.dataStoreID)
            } else {
                active.releaseRequested = true
                activeLeases[lease.dataStoreID] = active
            }
        }
    }

    struct V2BrowserStateRestoreFailure: Error, Equatable {
        enum Code: Equatable {
            case documentReadFailed
            case documentNotRegular
            case documentTooLarge
            case malformedDocument
            case unsupportedSchemaVersion
            case invalidURL
            case invalidCookie
            case duplicateCookie
            case cookieLimitExceeded
            case storageEntryLimitExceeded
            case storageKeyTooLarge
            case storageValueTooLarge
            case frameSelectorTooLarge
            case originMismatch
            case navigationMismatch
            case navigationCancelled
            case navigationFailed
            case navigationTimedOut
            case navigationPermissionDenied
            case navigationUnavailable
            case surfaceUnavailable
            case navigationBusy
            case restoreInvalidated
            case cookieInstallTimedOut
            case cookieInstallFailed
            case storageApplyTimedOut
            case storageApplyFailed
            case frameSelectorApplyTimedOut
            case frameSelectorApplyFailed
        }

        let code: Code
        let message: String
        let cookiesMayHaveBeenMutated: Bool
        let cookieCount: Int
        let storageMayHaveBeenMutated: Bool

        init(
            code: Code,
            message: String,
            cookiesMayHaveBeenMutated: Bool = false,
            cookieCount: Int = 0,
            storageMayHaveBeenMutated: Bool = false
        ) {
            self.code = code
            self.message = message
            self.cookiesMayHaveBeenMutated = cookiesMayHaveBeenMutated
            self.cookieCount = cookieCount
            self.storageMayHaveBeenMutated = storageMayHaveBeenMutated
        }
    }

    enum V2BrowserStateRestorer {
        static let currentSchemaVersion = 1

        struct PreparedState {
            let targetURL: URL
            let cookies: [HTTPCookie]
            let storage: V2BrowserStateStoragePayload
            let frameSelector: String?
        }

        static func restore(
            fileURL: URL,
            limits: V2BrowserStateRestoreLimits = .standard,
            using operations: V2BrowserStateRestoreOperations
        ) -> Result<Void, V2BrowserStateRestoreFailure> {
            switch prepare(fileURL: fileURL, limits: limits) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let state):
                return execute(state, using: operations)
            }
        }

        static func prepare(
            fileURL: URL,
            limits: V2BrowserStateRestoreLimits = .standard
        ) -> Result<PreparedState, V2BrowserStateRestoreFailure> {
            let byteLimit = max(0, limits.documentByteLimit)
            let readCount: Int
            let (limitPlusOne, overflow) = byteLimit.addingReportingOverflow(1)
            readCount = overflow ? Int.max : limitPlusOne

            let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .documentReadFailed,
                        message: String(cString: strerror(errno))
                    )
                )
            }
            var fileStatus = stat()
            guard fstat(descriptor, &fileStatus) == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(descriptor)
                return .failure(failure(.documentReadFailed, message))
            }
            guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(descriptor)
                return .failure(
                    failure(.documentNotRegular, "Browser state path must identify a regular file")
                )
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }

            let data: Data
            do {
                data = try handle.read(upToCount: readCount) ?? Data()
            } catch {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .documentReadFailed,
                        message: error.localizedDescription
                    )
                )
            }


            return prepare(data: data, limits: limits)
        }

        static func prepare(
            data: Data,
            limits: V2BrowserStateRestoreLimits = .standard
        ) -> Result<PreparedState, V2BrowserStateRestoreFailure> {
            let byteLimit = max(0, limits.documentByteLimit)
            guard data.count <= byteLimit else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .documentTooLarge,
                        message: "Browser state document exceeds \(byteLimit) bytes"
                    )
                )
            }

            let raw: [String: Any]
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state document must be a JSON object"
                        )
                    )
                }
                raw = object
            } catch {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .malformedDocument,
                        message: error.localizedDescription
                    )
                )
            }

            if let rawSchemaVersion = raw["schema_version"] {
                guard let schemaVersion = rawSchemaVersion as? NSNumber,
                      CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
                      schemaVersion.doubleValue == Double(schemaVersion.intValue),
                      schemaVersion.intValue == currentSchemaVersion else {
                    return .failure(
                        failure(.unsupportedSchemaVersion, "Unsupported browser state schema version")
                    )
                }
            }

            guard let rawURL = raw["url"] as? String,
                  !rawURL.isEmpty,
                  rawURL.utf8.count <= max(0, limits.urlByteLimit),
                  let targetURL = URL(string: rawURL),
                  originString(for: targetURL) != nil else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .invalidURL,
                        message: "Browser state URL must be an absolute HTTP or HTTPS URL"
                    )
                )
            }

            let cookieRows: [[String: Any]]
            if let rawCookies = raw["cookies"] {
                guard let rows = rawCookies as? [[String: Any]] else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state cookies must be an array of objects"
                        )
                    )
                }
                cookieRows = rows
            } else {
                cookieRows = []
            }
            guard cookieRows.count <= max(0, limits.cookieCountLimit) else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .cookieLimitExceeded,
                        message: "Browser state cookie count exceeds \(max(0, limits.cookieCountLimit))"
                    )
                )
            }

            var cookies: [HTTPCookie] = []
            cookies.reserveCapacity(cookieRows.count)
            var cookieIdentities = Set<String>()
            for row in cookieRows {
                guard let cookie = makeCookie(from: row, fallbackURL: targetURL) else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .invalidCookie,
                            message: "Browser state contains an invalid cookie"
                        )
                    )
                }
                let normalizedDomain = cookie.domain
                    .lowercased()
                    .drop(while: { $0 == "." })
                let identity = "\(normalizedDomain)\u{0}\(cookie.name)\u{0}\(cookie.path)"
                guard cookieIdentities.insert(identity).inserted else {
                    return .failure(
                        failure(.duplicateCookie, "Browser state contains duplicate cookie identities")
                    )
                }
                cookies.append(cookie)
            }

            let storageObject: [String: Any]
            if let rawStorage = raw["storage"] {
                guard let dictionary = rawStorage as? [String: Any] else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state storage must be an object"
                        )
                    )
                }
                storageObject = dictionary
            } else {
                storageObject = [:]
            }

            let localStorage: [String: String]
            switch storageMap(named: "local", in: storageObject, limits: limits) {
            case .success(let map):
                localStorage = map
            case .failure(let failure):
                return .failure(failure)
            }
            let sessionStorage: [String: String]
            switch storageMap(named: "session", in: storageObject, limits: limits) {
            case .success(let map):
                sessionStorage = map
            case .failure(let failure):
                return .failure(failure)
            }

            let frameSelector: String?
            if let rawFrameSelector = raw["frame_selector"], !(rawFrameSelector is NSNull) {
                guard let selector = rawFrameSelector as? String else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .malformedDocument,
                            message: "Browser state frame selector must be a string or null"
                        )
                    )
                }
                guard selector.utf8.count <= max(0, limits.frameSelectorByteLimit) else {
                    return .failure(
                        V2BrowserStateRestoreFailure(
                            code: .frameSelectorTooLarge,
                            message: "Browser state frame selector exceeds \(max(0, limits.frameSelectorByteLimit)) bytes"
                        )
                    )
                }
                frameSelector = selector.isEmpty ? nil : selector
            } else {
                frameSelector = nil
            }

            guard let expectedOrigin = originString(for: targetURL) else {
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .invalidURL,
                        message: "Browser state URL has no storage origin"
                    )
                )
            }
            return .success(
                PreparedState(
                    targetURL: targetURL,
                    cookies: cookies,
                    storage: V2BrowserStateStoragePayload(
                        expectedOrigin: expectedOrigin,
                        executionOrigin: expectedOrigin,
                        local: localStorage,
                        session: sessionStorage
                    ),
                    frameSelector: frameSelector
                )
            )
        }

        static func encodeDocument(
            url: URL?,
            cookies: [[String: Any]],
            storage: Any,
            frameSelector: String?,
            limits: V2BrowserStateRestoreLimits = .standard
        ) -> Result<Data, V2BrowserStateRestoreFailure> {
            // Saved state is origin-bound. Blank/about:blank tabs intentionally fail URL
            // validation so every reported save success is loadable by the same contract.
            let raw: [String: Any] = [
                "schema_version": currentSchemaVersion,
                "url": url?.absoluteString ?? "",
                "cookies": cookies,
                "storage": storage,
                "frame_selector": frameSelector ?? NSNull(),
            ]
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: raw,
                    options: [.prettyPrinted, .sortedKeys]
                )
                switch prepare(data: data, limits: limits) {
                case .success:
                    return .success(data)
                case .failure(let failure):
                    return .failure(failure)
                }
            } catch {
                return .failure(failure(.malformedDocument, error.localizedDescription))
            }
        }


        static func execute(
            _ state: PreparedState,
            using operations: V2BrowserStateRestoreOperations
        ) -> Result<Void, V2BrowserStateRestoreFailure> {
            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated"))
            }
            switch operations.installCookies(state.cookies, state.targetURL) {
            case .succeeded:
                break
            case .timedOut:
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .cookieInstallTimedOut,
                        message: "Timed out installing browser state cookies",
                        cookiesMayHaveBeenMutated: !state.cookies.isEmpty,
                        cookieCount: state.cookies.count
                    )
                )
            case .failed(let message), .originMismatch(let message):
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .cookieInstallFailed,
                        message: message,
                        cookiesMayHaveBeenMutated: !state.cookies.isEmpty,
                        cookieCount: state.cookies.count
                    )
                )
            case .unavailable(let message):
                return .failure(
                    V2BrowserStateRestoreFailure(
                        code: .surfaceUnavailable,
                        message: message,
                        cookiesMayHaveBeenMutated: !state.cookies.isEmpty,
                        cookieCount: state.cookies.count
                    )
                )
            }

            let cookiesMutated = !state.cookies.isEmpty
            let cookieCount = state.cookies.count
            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }

            let committed: V2BrowserStateNavigationMilestone
            let finished: V2BrowserStateNavigationMilestone
            switch operations.navigateAndWait(state.targetURL) {
            case .finished(let committedMilestone, let finishedMilestone):
                committed = committedMilestone
                finished = finishedMilestone
            case .cancelled:
                return .failure(failure(.navigationCancelled, "Browser state navigation was cancelled", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .timedOut:
                operations.cancelNavigation()
                return .failure(failure(.navigationTimedOut, "Timed out waiting for browser state navigation", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .failed(let message):
                return .failure(failure(.navigationFailed, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .permissionDenied:
                return .failure(failure(.navigationPermissionDenied, "Insecure HTTP navigation is not allowed", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .unavailable:
                return .failure(failure(.navigationUnavailable, "Browser surface became unavailable", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            case .busy:
                return .failure(failure(.navigationBusy, "Another browser state navigation is active", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }

            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }
            guard committed.navigationID == finished.navigationID else {
                return .failure(
                    failure(
                        .navigationMismatch,
                        "Browser state navigation commit and finish do not refer to the same navigation",
                        cookiesMutated: cookiesMutated,
                        cookieCount: cookieCount
                    )
                )
            }
            guard originString(for: committed.url) == state.storage.expectedOrigin,
                  originString(for: finished.url) == state.storage.expectedOrigin else {
                return .failure(
                    failure(.originMismatch, "Browser state navigation finished on an unexpected origin", cookiesMutated: cookiesMutated, cookieCount: cookieCount)
                )
            }

            guard let committedExecutionOrigin = originString(for: committed.executionURL),
                  let finishedExecutionOrigin = originString(for: finished.executionURL),
                  committedExecutionOrigin == finishedExecutionOrigin else {
                return .failure(failure(.originMismatch, "Browser state navigation execution origin changed", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }
            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount))
            }
            let storage = V2BrowserStateStoragePayload(
                expectedOrigin: state.storage.expectedOrigin,
                executionOrigin: finishedExecutionOrigin,
                local: state.storage.local,
                session: state.storage.session
            )
            switch operations.applyStorage(storage) {
            case .succeeded:
                break
            case .timedOut:
                return .failure(failure(.storageApplyTimedOut, "Timed out applying browser storage", cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .failed(let message):
                return .failure(failure(.storageApplyFailed, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .originMismatch(let message):
                return .failure(failure(.originMismatch, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .unavailable(let message):
                return .failure(failure(.surfaceUnavailable, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            }

            guard operations.leaseIsValid() else {
                return .failure(failure(.restoreInvalidated, "Browser state restore was invalidated", cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            }
            switch operations.applyFrameSelector(state.frameSelector) {
            case .succeeded:
                return .success(())
            case .timedOut:
                return .failure(failure(.frameSelectorApplyTimedOut, "Timed out applying frame selector", cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .failed(let message), .originMismatch(let message):
                return .failure(failure(.frameSelectorApplyFailed, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            case .unavailable(let message):
                return .failure(failure(.surfaceUnavailable, message, cookiesMutated: cookiesMutated, cookieCount: cookieCount, storageMutated: true))
            }
        }

        static func originString(for url: URL) -> String? {
            guard let rawScheme = url.scheme?.lowercased(),
                  rawScheme == "http" || rawScheme == "https",
                  let rawHost = url.host?.lowercased(),
                  !rawHost.isEmpty else {
                return nil
            }
            let unbracketedHost = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let host = unbracketedHost.contains(":") ? "[\(unbracketedHost)]" : unbracketedHost
            let defaultPort = rawScheme == "https" ? 443 : 80
            if let port = url.port, port != defaultPort {
                return "\(rawScheme)://\(host):\(port)"
            }
            return "\(rawScheme)://\(host)"
        }

        private static func storageMap(
            named name: String,
            in storage: [String: Any],
            limits: V2BrowserStateRestoreLimits
        ) -> Result<[String: String], V2BrowserStateRestoreFailure> {
            guard let rawMap = storage[name] else { return .success([:]) }
            guard let map = rawMap as? [String: Any] else {
                return .failure(
                    failure(.malformedDocument, "Browser state \(name) storage must be an object")
                )
            }
            guard map.count <= max(0, limits.storageEntryCountLimit) else {
                return .failure(
                    failure(
                        .storageEntryLimitExceeded,
                        "Browser state \(name) storage exceeds \(max(0, limits.storageEntryCountLimit)) entries"
                    )
                )
            }

            var validated: [String: String] = [:]
            validated.reserveCapacity(map.count)
            for (key, rawValue) in map {
                guard key.utf8.count <= max(0, limits.storageKeyByteLimit) else {
                    return .failure(
                        failure(.storageKeyTooLarge, "Browser state storage key exceeds the byte limit")
                    )
                }
                guard let value = rawValue as? String else {
                    return .failure(
                        failure(.malformedDocument, "Browser state storage values must be strings")
                    )
                }
                guard value.utf8.count <= max(0, limits.storageValueByteLimit) else {
                    return .failure(
                        failure(.storageValueTooLarge, "Browser state storage value exceeds the byte limit")
                    )
                }
                validated[key] = value
            }
            return .success(validated)
        }

        private static func makeCookie(from raw: [String: Any], fallbackURL: URL) -> HTTPCookie? {
            guard let name = raw["name"] as? String, !name.isEmpty,
                  let value = raw["value"] as? String else {
                return nil
            }

            let originURL: URL
            if let rawCookieURL = raw["url"] {
                guard let cookieURLString = rawCookieURL as? String,
                      let cookieURL = URL(string: cookieURLString),
                      originString(for: cookieURL) != nil else {
                    return nil
                }
                originURL = cookieURL
            } else {
                originURL = fallbackURL
            }

            let domain: String
            if let rawDomain = raw["domain"] {
                guard let cookieDomain = rawDomain as? String, !cookieDomain.isEmpty else { return nil }
                domain = cookieDomain
            } else {
                guard let host = originURL.host, !host.isEmpty else { return nil }
                domain = host
            }

            let path: String
            if let rawPath = raw["path"] {
                guard let cookiePath = rawPath as? String, cookiePath.hasPrefix("/") else { return nil }
                path = cookiePath
            } else {
                path = "/"
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .originURL: originURL,
                .domain: domain,
                .path: path,
            ]
            if let rawSecure = raw["secure"] {
                guard let secure = rawSecure as? Bool else { return nil }
                if secure { properties[.secure] = "TRUE" }
            }
            if let rawHTTPOnly = raw["http_only"] {
                guard let httpOnly = rawHTTPOnly as? Bool else { return nil }
                if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            }
            if let rawSameSite = raw["same_site"], !(rawSameSite is NSNull) {
                guard let sameSite = rawSameSite as? String,
                      sameSite == HTTPCookieStringPolicy.sameSiteStrict.rawValue
                        || sameSite == HTTPCookieStringPolicy.sameSiteLax.rawValue else {
                    return nil
                }
                properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite)
            }
            if let rawExpires = raw["expires"], !(rawExpires is NSNull) {
                guard let expires = rawExpires as? NSNumber,
                      CFGetTypeID(expires) != CFBooleanGetTypeID(),
                      expires.doubleValue.isFinite else {
                    return nil
                }
                properties[.expires] = Date(timeIntervalSince1970: expires.doubleValue)
            }
            return HTTPCookie(properties: properties)
        }

        private static func failure(
            _ code: V2BrowserStateRestoreFailure.Code,
            _ message: String,
            cookiesMutated: Bool = false,
            cookieCount: Int = 0,
            storageMutated: Bool = false
        ) -> V2BrowserStateRestoreFailure {
            V2BrowserStateRestoreFailure(
                code: code,
                message: message,
                cookiesMayHaveBeenMutated: cookiesMutated,
                cookieCount: cookieCount,
                storageMayHaveBeenMutated: storageMutated
            )
        }
    }

    private enum V2BrowserJavaScriptExecutionOutcome {
        case completed(Any?)
        case frameUnavailable(String)
        case failed(String)
    }

    private struct V2BrowserScreenshotContext: Sendable {
        let workspaceId: UUID
        let surfaceId: UUID
    }

    private enum V2BrowserScreenshotStartFailure: Sendable {
        case tabManagerUnavailable
        case workspaceNotFound
        case noFocusedSurface
        case surfaceNotBrowser(UUID)
    }

    private enum V2BrowserScreenshotStartOutcome: Sendable {
        case started(V2BrowserScreenshotContext)
        case failed(V2BrowserScreenshotStartFailure)
    }

    private enum V2BrowserScreenshotCaptureOutcome: Sendable {
        case captured(Data)
        case failed
        case timedOut
    }

    private enum V2BrowserScreenshotWaitPhase: Sendable {
        case pending
        case completed(V2BrowserScreenshotCaptureOutcome)
    }

    private final class V2BrowserScreenshotWaitState: Sendable {
        private let phase = OSAllocatedUnfairLock(initialState: V2BrowserScreenshotWaitPhase.pending)
        private let completionSemaphore = DispatchSemaphore(value: 0)

        func complete(_ outcome: V2BrowserScreenshotCaptureOutcome) {
            let shouldSignal = phase.withLock { phase in
                guard case .pending = phase else { return false }
                phase = .completed(outcome)
                return true
            }
            if shouldSignal {
                completionSemaphore.signal()
            }
        }

        func wait(timeout: TimeInterval) -> V2BrowserScreenshotCaptureOutcome {
            _ = completionSemaphore.wait(timeout: .now() + timeout)
            return phase.withLock { phase in
                switch phase {
                case .pending:
                    phase = .completed(.timedOut)
                    return .timedOut
                case .completed(let outcome):
                    return outcome
                }
            }
        }
    }

    private struct V2BrowserScreenshotDebugGate: Sendable {
        let pendingMarkerPath: String
        let releaseMarkerPath: String
    }

    private struct V2BrowserDownloadPathContext: Sendable {
        let workspaceId: UUID
        let surfaceId: UUID
    }

    private enum V2BrowserDownloadPathLookupFailure: Sendable {
        case tabManagerUnavailable
        case workspaceNotFound
        case noFocusedSurface
        case surfaceNotBrowser(UUID)
    }

    private enum V2BrowserDownloadPathLookup: Sendable {
        case resolved(V2BrowserDownloadPathContext)
        case failed(V2BrowserDownloadPathLookupFailure)
    }

    private enum V2BrowserDownloadPathWaitResult: Sendable {
        case ready
        case timedOut
        case failedToWatch
    }

    // SAFETY: Every mutable field is accessed only while `lock` is held. The immutable
    // semaphores provide the completion and cancellation acknowledgements across queues.
    private final class V2BrowserDownloadPathWaitState: @unchecked Sendable {
        private let lock = NSLock()
        private let completionSemaphore = DispatchSemaphore(value: 0)
        private let cancellationSemaphore = DispatchSemaphore(value: 0)
        private var source: DispatchSourceFileSystemObject?
        private var fileDescriptor: Int32?
        private var result: Bool?
        private var cancellationAcknowledged = false

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        func install(source: DispatchSourceFileSystemObject) {
            lock.lock()
            self.source = source
            lock.unlock()
        }

        func finish(ready: Bool) {
            let sourceToCancel: DispatchSourceFileSystemObject?
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = ready
            sourceToCancel = source
            lock.unlock()

            sourceToCancel?.cancel()
            completionSemaphore.signal()
        }

        func waitForResult() -> Bool {
            completionSemaphore.wait()
            lock.lock()
            defer { lock.unlock() }
            return result ?? false
        }

        func closeFileDescriptorAndAcknowledgeCancellation() {
            let descriptorToClose: Int32?
            let shouldSignal: Bool
            lock.lock()
            if cancellationAcknowledged {
                descriptorToClose = nil
                shouldSignal = false
            } else {
                cancellationAcknowledged = true
                descriptorToClose = fileDescriptor
                fileDescriptor = nil
                source = nil
                shouldSignal = true
            }
            lock.unlock()

            if let descriptorToClose {
                Darwin.close(descriptorToClose)
            }
            if shouldSignal {
                cancellationSemaphore.signal()
            }
        }

        func waitForCancellationAcknowledgement() {
            cancellationSemaphore.wait()
        }
    }

    nonisolated func v2BrowserWithPanel(
        params: [String: Any],
        _ body: @MainActor (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    private nonisolated func v2JSONLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    private func v2NormalizeJSValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is V2BrowserUndefinedSentinel {
            return [
                Self.v2BrowserEvalEnvelopeTypeKey: Self.v2BrowserEvalEnvelopeTypeUndefined,
                Self.v2BrowserEvalEnvelopeValueKey: NSNull()
            ]
        }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = v2NormalizeJSValue(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { v2NormalizeJSValue($0) }
        }
        return String(describing: value)
    }

    private enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    private func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        contentWorld: WKContentWorld,
        webKitCompletionDidDrain: (() -> Void)? = nil
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            if preferAsync {
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                    webKitCompletionDidDrain?()
                    switch result {
                    case .success(let value):
                        finish(value, nil)
                    case .failure(let error):
                        finish(nil, error.localizedDescription)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    webKitCompletionDidDrain?()
                    if let error {
                        finish(nil, error.localizedDescription)
                    } else {
                        finish(value, nil)
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        if Thread.isMainThread {
            let runLoop = CFRunLoopGetCurrent()
            var resolved = false
            var timedOut = false
            var result: T?

            let finish: (T) -> Void = { value in
                guard !resolved else { return }
                resolved = true
                result = value
                CFRunLoopStop(runLoop)
            }

            start(finish)
            guard !resolved else { return result }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !resolved else { return }
                resolved = true
                timedOut = true
                CFRunLoopStop(runLoop)
            }

            CFRunLoopRun()
            return timedOut ? nil : result
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T?
        start { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> Bool {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __programaEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__programaEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__programaEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true
        case .failure:
            return false
        }
    }

    nonisolated func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    nonisolated func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    func v2BrowserBumpNavigationGeneration(forSurface surfaceId: UUID) {
        browserRPCState.advanceNavigationGeneration(for: surfaceId)
    }

    func v2BrowserPostProcessSnapshotResult(_ browserResult: [String: Any]) -> V2BrowserSnapshotContent {
        let reasonOrder = [
            "entry_limit", "node_limit", "text_inspection_limit", "entry_byte_limit", "selector_byte_limit",
            "name_byte_limit", "role_byte_limit", "title_byte_limit", "url_byte_limit"
        ]
        let browserReasons = Set(
            (browserResult["truncation_reasons"] as? [String] ?? [])
                .prefix(reasonOrder.count)
                .filter(reasonOrder.contains)
        )
        var activeReasons = browserReasons

        let boundedTitle = v2BrowserBoundUTF8(
            (browserResult["title"] as? String) ?? "",
            byteLimit: Self.v2BrowserSnapshotTitleByteLimit
        )
        let boundedURL = v2BrowserBoundUTF8(
            (browserResult["url"] as? String) ?? "",
            byteLimit: Self.v2BrowserSnapshotURLByteLimit
        )
        if boundedTitle.truncated { activeReasons.insert("title_byte_limit") }
        if boundedURL.truncated { activeReasons.insert("url_byte_limit") }

        let allowedRoles: Set<String> = [
            "application", "article", "button", "cell", "checkbox", "columnheader",
            "combobox", "directory", "document", "generic", "grid", "gridcell", "group",
            "heading", "link", "list", "listbox", "listitem", "main", "menu", "menubar",
            "menuitem", "menuitemcheckbox", "menuitemradio", "navigation", "none", "option",
            "presentation", "radio", "region", "row", "rowgroup", "rowheader", "searchbox",
            "slider", "spinbutton", "switch", "tab", "table", "tablist", "textbox", "toolbar",
            "tree", "treegrid", "treeitem"
        ]
        var entries: [[String: Any]] = []
        entries.reserveCapacity(Self.v2BrowserSnapshotEntryLimit)
        var seenSelectors: Set<String> = []
        var entryBytes = 0
        var swiftSelectorSkipped = 0
        var swiftNameTruncated = 0
        var swiftRoleSkipped = 0

        func boundedEntryDepth(_ value: Any?) -> Int {
            if value is Bool { return 0 }
            if let depth = value as? Int {
                return min(Self.v2BrowserSnapshotMaxDepth, max(0, depth))
            }
            guard let number = value as? NSNumber else { return 0 }
            let depth = number.doubleValue
            guard depth.isFinite else {
                return depth.sign == .plus ? Self.v2BrowserSnapshotMaxDepth : 0
            }
            if depth <= 0 { return 0 }
            if depth >= Double(Self.v2BrowserSnapshotMaxDepth) {
                return Self.v2BrowserSnapshotMaxDepth
            }
            return Int(depth)
        }

        let rawEntries = (browserResult["entries"] as? [[String: Any]]) ?? []
        let rawEntriesTruncated = rawEntries.count > Self.v2BrowserSnapshotRawEntryLimit
        for untrustedEntry in rawEntries.prefix(Self.v2BrowserSnapshotRawEntryLimit) {
            guard let rawSelector = untrustedEntry["selector"] as? String, !rawSelector.isEmpty else { continue }
            let boundedSelector = v2BrowserBoundUTF8(
                rawSelector,
                byteLimit: Self.v2BrowserElementRefSelectorByteLimit
            )
            guard !boundedSelector.truncated else {
                swiftSelectorSkipped += 1
                activeReasons.insert("selector_byte_limit")
                continue
            }
            let selector = boundedSelector.value
            guard seenSelectors.insert(selector).inserted else { continue }

            let boundedName = v2BrowserBoundUTF8(
                (untrustedEntry["name"] as? String) ?? "",
                byteLimit: Self.v2BrowserSnapshotNameByteLimit
            )
            if boundedName.truncated {
                swiftNameTruncated += 1
                activeReasons.insert("name_byte_limit")
            }

            let rawRole = (untrustedEntry["role"] as? String) ?? ""
            let boundedRawRole = v2BrowserBoundUTF8(rawRole, byteLimit: Self.v2BrowserSnapshotRoleByteLimit)
            guard !boundedRawRole.truncated else {
                swiftRoleSkipped += 1
                activeReasons.insert("role_byte_limit")
                continue
            }
            let role = boundedRawRole.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !role.isEmpty,
                  role.utf8.count <= Self.v2BrowserSnapshotRoleByteLimit,
                  allowedRoles.contains(role) else {
                swiftRoleSkipped += 1
                activeReasons.insert("role_byte_limit")
                continue
            }

            guard entries.count < Self.v2BrowserSnapshotEntryLimit else {
                activeReasons.insert("entry_limit")
                break
            }
            let selectorBytes = selector.utf8.count
            let nameBytes = boundedName.value.utf8.count
            let roleBytes = role.utf8.count
            let (selectorAndNameBytes, firstOverflow) = selectorBytes.addingReportingOverflow(nameBytes)
            let (candidateBytes, secondOverflow) = selectorAndNameBytes.addingReportingOverflow(roleBytes)
            let (nextEntryBytes, totalOverflow) = entryBytes.addingReportingOverflow(candidateBytes)
            guard !firstOverflow, !secondOverflow, !totalOverflow,
                  nextEntryBytes <= Self.v2BrowserSnapshotEntryByteLimit else {
                activeReasons.insert("entry_byte_limit")
                break
            }

            let entry: [String: Any] = [
                "selector": selector,
                "name": boundedName.value,
                "role": role,
                "depth": boundedEntryDepth(untrustedEntry["depth"])
            ]
            entries.append(entry)
            entryBytes = nextEntryBytes
        }

        func browserCounter(_ key: String, reason: String) -> Int {
            guard browserReasons.contains(reason) else { return 0 }
            let raw = (browserResult[key] as? Int) ?? (browserResult[key] as? NSNumber)?.intValue ?? 0
            return min(Self.v2BrowserSnapshotNodeVisitLimit, max(0, raw))
        }

        let boundedText = v2BrowserBoundCharacters(
            (browserResult["text"] as? String) ?? "",
            limit: Self.v2BrowserSnapshotTextCharacterLimit
        )
        let boundedHTML = v2BrowserBoundCharacters(
            (browserResult["html"] as? String) ?? "",
            limit: Self.v2BrowserSnapshotHTMLCharacterLimit
        )
        let rawVisitedNodes = (browserResult["visited_nodes"] as? Int)
            ?? (browserResult["visited_nodes"] as? NSNumber)?.intValue
            ?? 0
        let visitedNodes = min(Self.v2BrowserSnapshotNodeVisitLimit, max(0, rawVisitedNodes))
        let rawTextInspectedUnits = (browserResult["text_inspected_units"] as? Int)
            ?? (browserResult["text_inspected_units"] as? NSNumber)?.intValue
            ?? 0
        let textInspectedUnits = min(
            Self.v2BrowserSnapshotTextInspectionLimit,
            max(0, rawTextInspectedUnits)
        )
        let orderedReasons = reasonOrder.filter(activeReasons.contains)
        let textTruncated = ((browserResult["text_truncated"] as? Bool) ?? false) || boundedText.truncated
        let htmlTruncated = ((browserResult["html_truncated"] as? Bool) ?? false) || boundedHTML.truncated
        var metadata: [String: Any] = [
            "truncated": rawEntriesTruncated || textTruncated || htmlTruncated
                || !orderedReasons.isEmpty || ((browserResult["truncated"] as? Bool) ?? false),
            "truncation_reasons": orderedReasons,
            "raw_entry_limit": Self.v2BrowserSnapshotRawEntryLimit,
            "element_limit": Self.v2BrowserSnapshotEntryLimit,
            "node_limit": Self.v2BrowserSnapshotNodeVisitLimit,
            "visited_nodes": visitedNodes,
            "text_inspection_limit": Self.v2BrowserSnapshotTextInspectionLimit,
            "text_inspected_units": textInspectedUnits,
            "entry_byte_limit": Self.v2BrowserSnapshotEntryByteLimit,
            "entry_bytes": entryBytes,
            "selector_byte_limit": Self.v2BrowserElementRefSelectorByteLimit,
            "selector_skipped_count": browserCounter("selector_skipped_count", reason: "selector_byte_limit") + swiftSelectorSkipped,
            "name_byte_limit": Self.v2BrowserSnapshotNameByteLimit,
            "name_truncated_count": browserCounter("name_truncated_count", reason: "name_byte_limit") + swiftNameTruncated,
            "role_byte_limit": Self.v2BrowserSnapshotRoleByteLimit,
            "role_skipped_count": browserCounter("role_skipped_count", reason: "role_byte_limit") + swiftRoleSkipped,
            "title_byte_limit": Self.v2BrowserSnapshotTitleByteLimit,
            "url_byte_limit": Self.v2BrowserSnapshotURLByteLimit
        ]
        if textTruncated {
            metadata["text_truncated"] = true
        }
        if htmlTruncated {
            metadata["html_truncated"] = true
        }
        return V2BrowserSnapshotContent(
            title: boundedTitle.value,
            url: boundedURL.value,
            entries: entries,
            text: boundedText.value,
            html: boundedHTML.value,
            metadata: metadata
        )
    }

    private func v2BrowserBoundUTF8(_ value: String, byteLimit: Int) -> (value: String, truncated: Bool) {
        var bytes = 0
        var boundary = value.startIndex
        for character in value {
            let characterBytes = String(character).utf8.count
            guard bytes <= byteLimit - characterBytes else {
                return (String(value[..<boundary]), true)
            }
            bytes += characterBytes
            boundary = value.index(after: boundary)
        }
        return (value, false)
    }

    private func v2BrowserBoundCharacters(_ value: String, limit: Int) -> (value: String, truncated: Bool) {
        guard let boundary = value.index(value.startIndex, offsetBy: limit, limitedBy: value.endIndex),
              boundary != value.endIndex else {
            return (value, false)
        }
        return (String(value[..<boundary]), true)
    }

    @MainActor
    func v2BrowserWaitForDownloadEvent(
        surfaceId: UUID,
        timeout: TimeInterval
    ) -> V2BrowserDownloadEventWaitOutcome {
        guard v2BrowserPendingDownloadEventWaiter == nil else {
            return .busy
        }
        if let queued = browserRPCState.consumeDownloadEvent(surfaceId: surfaceId) {
            return .event(queued.event, droppedEvents: queued.droppedEvents)
        }

        let waiterId = UUID()
        let outcome: V2BrowserDownloadEventWaitOutcome? = v2AwaitCallback(timeout: timeout) { finish in
            v2BrowserPendingDownloadEventWaiter = V2BrowserDownloadEventWaiter(
                surfaceId: surfaceId,
                id: waiterId,
                finish: finish
            )
        }
        if let outcome {
            return outcome
        }

        if v2BrowserPendingDownloadEventWaiter?.id == waiterId {
            v2BrowserPendingDownloadEventWaiter = nil
        }
        return .timedOut
    }

    func v2BrowserPermanentlyRemoveSurfaceState(surfaceId: UUID) {
        browserRPCState.permanentlyRemoveSurface(surfaceId)
    }

    func v2BrowserElementRefResourceExhaustedResult(
        surfaceId: UUID,
        capacity: V2BrowserElementRefCapacity
    ) -> V2CallResult {
        let data: [String: AnyHashable] = [
            "surface_id": surfaceId.uuidString,
            "limit": capacity.limit,
            "scope": "navigation",
            "retry": "navigate or reuse an existing selector",
            "requested_unique": capacity.requestedUnique,
            "remaining": capacity.remaining,
            "selector_byte_limit": capacity.selectorByteLimit,
            "byte_limit": capacity.byteLimit,
            "requested_bytes": capacity.requestedBytes,
            "remaining_bytes": capacity.remainingBytes
        ]
        return .err(
            code: "resource_exhausted",
            message: "Browser element reference limit reached for this page",
            data: data
        )
    }

    private func v2BrowserWithAllocatedElementRef(
        surfaceId: UUID,
        selector: String,
        buildResult: (String) -> V2CallResult
    ) -> V2CallResult {
        switch browserRPCState.allocateElementRefs(surfaceId: surfaceId, selectors: [selector]) {
        case .allocated(let refs):
            guard let ref = refs.first else {
                return .err(code: "internal_error", message: "Element reference allocation failed", data: nil)
            }
            return buildResult(ref)
        case .resourceExhausted(let capacity):
            return v2BrowserElementRefResourceExhaustedResult(surfaceId: surfaceId, capacity: capacity)
        }
    }

    private enum V2BrowserSelectorLookup {
        case literal(String)
        case notFound
        case stale
    }

    /// Single shared resolve helper backing both `v2BrowserResolveSelector` (used by every
    /// click/type/query consumer) and `v2BrowserSelectorResolutionError` (the structured error
    /// to surface when resolution fails). Distinguishes a ref that once resolved but whose
    /// surface has since navigated (`.stale`) from any other miss (`.notFound`) so callers can
    /// report `stale_element` instead of a generic `not_found` (M6a).
    private func v2BrowserLookupSelector(_ rawSelector: String, surfaceId: UUID) -> V2BrowserSelectorLookup {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        // "@..." is reserved for element-ref tokens (never a literal CSS selector), so any
        // "@"-prefixed input that isn't a well-formed "@e<ordinal>" ref must report notFound
        // rather than silently falling through to literal CSS-selector interpretation.
        if trimmed.hasPrefix("@"), !trimmed.hasPrefix("@e") {
            return .notFound
        }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        guard let refKey else { return .literal(trimmed) }

        guard let entry = v2BrowserElementRefs[refKey], entry.surfaceId == surfaceId else {
            return .notFound
        }
        guard entry.navigationGeneration == browserRPCState.navigationGeneration(for: surfaceId) else {
            return .stale
        }
        return .literal(entry.selector)
    }

    func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        if case .literal(let selector) = v2BrowserLookupSelector(rawSelector, surfaceId: surfaceId) {
            return selector
        }
        return nil
    }

    /// Error to return when `v2BrowserResolveSelector` returns nil for `rawSelector` against
    /// `surfaceId`. Every consumer of the element-ref maps (resolve/click/type/query paths)
    /// should surface this instead of hand-rolling a generic not_found, so a stale ref reports
    /// `stale_element` rather than being indistinguishable from "never allocated".
    func v2BrowserSelectorResolutionError(_ rawSelector: String, surfaceId: UUID) -> V2CallResult {
        switch v2BrowserLookupSelector(rawSelector, surfaceId: surfaceId) {
        case .stale:
            return .err(
                code: "stale_element",
                message: "element ref was captured on a previous page",
                data: ["ref": rawSelector]
            )
        case .notFound, .literal:
            return .err(code: "not_found", message: "Element reference not found", data: ["selector": rawSelector])
        }
    }

    func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2BrowserFrameSelectorBySurface[surfaceId]
    }

    @discardableResult
    func v2BrowserApplyFrameSelector(
        _ selector: String?,
        surfaceId: UUID,
        source: V2BrowserFrameSelectorSource
    ) -> V2BrowserFrameSelectorApplyResult {
        _ = source
        guard let selector, !selector.isEmpty else {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .applied
        }
        guard selector.utf8.count <= Self.v2BrowserElementRefSelectorByteLimit else {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .rejected(limit: Self.v2BrowserElementRefSelectorByteLimit)
        }
        v2BrowserFrameSelectorBySurface[surfaceId] = selector
        return .applied
    }

    private func v2RunBrowserJavaScriptOutcome(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> V2BrowserJavaScriptExecutionOutcome {
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            const __programaFrameSelector = \(selectorLiteral);
            let __programaDoc = null;
            try {
              const __programaFrame = document.querySelector(__programaFrameSelector);
              const __programaFrameName = __programaFrame?.namespaceURI === 'http://www.w3.org/1999/xhtml'
                ? __programaFrame.localName
                : null;
              if (__programaFrameName !== 'iframe' && __programaFrameName !== 'frame') {
                return { __programa_status: 'frame_unavailable' };
              }
              __programaDoc = __programaFrame.contentDocument;
              if (!__programaDoc) return { __programa_status: 'frame_unavailable' };
            } catch (_) {
              return { __programa_status: 'frame_unavailable' };
            }
            """
        } else {
            framePrelude = "const __programaDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __programaMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __programaEvalInFrame = async function() {
          const document = __programaDoc;
          const window = __programaDoc.defaultView;
          \(executionBlock)
          const __value = await __programaMaybeAwait(__r);
          return {
            __programa_status: 'completed',
            __programa_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __programa_v: __value
          };
        };

        return await __programaEvalInFrame();
        """

        var rawResult = v2RunJavaScript(
            webView,
            script: asyncFunctionBody,
            timeout: timeout,
            preferAsync: true,
            contentWorld: useEval ? .page : .defaultClient
        )

        // Non-eval callers (browser.wait, generated selector actions, and the snapshot
        // collector) run in the isolated `.defaultClient` world above, but the page-world
        // script environment can still transiently fail right after a fresh navigation (e.g.
        // browser.open_split returns before the page-world script context is ready). Retry once
        // against `.page` before giving up so a single transient failure doesn't turn into an
        // immediate false/timeout instead of the caller's normal polling/retry behavior.
        if !useEval, case .failure(let isolatedMessage) = rawResult {
            let pageWorldResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .page
            )
            switch pageWorldResult {
            case .success:
                rawResult = pageWorldResult
            case .failure(let pageMessage):
                if pageMessage != isolatedMessage {
                    rawResult = .failure("\(isolatedMessage) (page-world retry: \(pageMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failed(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let status = dict["__programa_status"] as? String else {
                return .completed(value)
            }
            if status == "frame_unavailable" {
                return .frameUnavailable(v2BrowserCurrentFrameSelector(surfaceId: surfaceId) ?? "")
            }
            guard status == "completed",
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .failed("Invalid browser JavaScript envelope")
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .completed(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .completed(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .failed("Invalid browser JavaScript value type")
            }
        }
    }

    private func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> V2JavaScriptResult {
        switch v2RunBrowserJavaScriptOutcome(
            webView,
            surfaceId: surfaceId,
            script: script,
            timeout: timeout,
            useEval: useEval
        ) {
        case .completed(let value):
            return .success(value)
        case .frameUnavailable(let selector):
            return .failure("Selected frame unavailable: \(selector)")
        case .failed(let message):
            return .failure(message)
        }
    }

    @MainActor
    func v2BrowserRunGeneratedSelectorAction(
        webView: WKWebView,
        surfaceId: UUID,
        selector rawSelector: String,
        action: V2BrowserGeneratedSelectorAction
    ) -> V2BrowserGeneratedSelectorActionOutcome {
        guard let selector = v2BrowserResolveSelector(rawSelector, surfaceId: surfaceId) else {
            return .elementNotFound
        }
        let selectorLiteral = v2JSONLiteral(selector)
        let script: String
        switch action {
        case .click:
            script = """
            (() => {
              const element = document.querySelector(\(selectorLiteral));
              if (!element) return { ok: false, error: 'not_found' };
              element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof element.click === 'function') {
                element.click();
              } else {
                element.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
              }
              return { ok: true };
            })()
            """
        }

        switch v2RunBrowserJavaScriptOutcome(
            webView,
            surfaceId: surfaceId,
            script: script,
            useEval: false
        ) {
        case .frameUnavailable(let selector):
            return .frameUnavailable(selector)
        case .failed(let message):
            return .failed(message)
        case .completed(let value):
            guard let result = value as? [String: Any] else {
                return .failed("Invalid generated selector action result")
            }
            if result["ok"] as? Bool == true {
                return .succeeded
            }
            if result["error"] as? String == "not_found" {
                return .elementNotFound
            }
            return .failed("Generated selector action failed")
        }
    }

    @MainActor
    func v2BrowserCollectSnapshotJavaScriptOutcome(
        webView: WKWebView,
        surfaceId: UUID,
        script: String
    ) -> V2BrowserSnapshotCollectionOutcome {
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            const __programaSnapshotFrameSelector = \(selectorLiteral);
            let __programaSnapshotDocument = null;
            try {
              const __programaSnapshotFrame = document.querySelector(__programaSnapshotFrameSelector);
              const __programaSnapshotFrameName = __programaSnapshotFrame?.namespaceURI === 'http://www.w3.org/1999/xhtml'
                ? __programaSnapshotFrame.localName
                : null;
              if (__programaSnapshotFrameName !== 'iframe' && __programaSnapshotFrameName !== 'frame') {
                return { __programa_snapshot_status: 'frame_unavailable' };
              }
              __programaSnapshotDocument = __programaSnapshotFrame.contentDocument;
              if (!__programaSnapshotDocument) {
                return { __programa_snapshot_status: 'frame_unavailable' };
              }
            } catch (_) {
              return { __programa_snapshot_status: 'frame_unavailable' };
            }
            """
        } else {
            framePrelude = "const __programaSnapshotDocument = document;"
        }

        let collectorBody = """
        \(framePrelude)
        const __programaCollectSnapshot = function() {
          const document = __programaSnapshotDocument;
          return \(script);
        };
        return {
          __programa_snapshot_status: 'collected',
          __programa_snapshot_value: __programaCollectSnapshot()
        };
        """
        switch v2RunJavaScript(
            webView,
            script: collectorBody,
            timeout: 10.0,
            preferAsync: true,
            contentWorld: .defaultClient
        ) {
        case .success(let value):
            guard let envelope = value as? [String: Any],
                  let status = envelope["__programa_snapshot_status"] as? String else {
                return .failed("Invalid snapshot collector envelope")
            }
            switch status {
            case "collected":
                guard let result = envelope["__programa_snapshot_value"] as? [String: Any] else {
                    return .failed("Invalid snapshot payload")
                }
                return .collected(result)
            case "frame_unavailable":
                return .frameUnavailable(v2BrowserCurrentFrameSelector(surfaceId: surfaceId) ?? "")
            default:
                return .failed("Unknown snapshot collector status")
            }
        case .failure(let message):
            return .failed(message)
        }
    }

    @MainActor
    func v2BrowserCollectSnapshotJavaScriptResult(
        webView: WKWebView,
        surfaceId: UUID,
        script: String
    ) -> [String: Any]? {
        guard case .collected(let result) = v2BrowserCollectSnapshotJavaScriptOutcome(
            webView: webView,
            surfaceId: surfaceId,
            script: script
        ) else {
            return nil
        }
        return result
    }

    func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    @MainActor
    private static func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated static func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown

    func v2MarkdownOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }

        // Resolve the path (expand ~ and standardize)
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        // Reject paths that aren't absolute after resolution
        guard filePath.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "Path must be absolute: \(filePath)", data: ["path": filePath])
        }

        // Validate the file exists and is a regular file (not a directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return .err(code: "not_found", message: "File not found: \(filePath)", data: ["path": filePath])
        }
        guard !isDir.boolValue else {
            return .err(code: "invalid_params", message: "Path is a directory, not a file: \(filePath)", data: ["path": filePath])
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return .err(code: "permission_denied", message: "File not readable: \(filePath)", data: ["path": filePath])
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let directionStr = v2String(params, "direction") ?? "right"
            guard let direction = parseSplitDirection(directionStr) else {
                result = .err(code: "invalid_params", message: "Invalid direction '\(directionStr)' (left|right|up|down)", data: nil)
                return
            }
            let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
            let insertFirst = (direction == .left || direction == .up)

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath,
                focus: v2FocusAllowed()
            )

            guard let markdownPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: markdownPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": markdownPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "path": filePath
            ])
        }
        return result
    }

    // MARK: - Browser

    func v2BrowserOpenSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let respectExternalOpenRules = v2Bool(params, "respect_external_open_rules") ?? false

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let url,
               respectExternalOpenRules,
               BrowserLinkOpenSettings.shouldOpenExternally(url) {
                guard BrowserLinkOpenSettings.openExternally(url) else {
                    result = .err(
                        code: "external_open_failed",
                        message: "Failed to open URL externally",
                        data: ["url": url.absoluteString]
                    )
                    return
                }
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(nil),
                    "pane_ref": v2Ref(kind: .pane, uuid: nil),
                    "surface_id": v2OrNull(nil),
                    "surface_ref": v2Ref(kind: .surface, uuid: nil),
                    "created_split": false,
                    "placement_strategy": "external",
                    "opened_externally": true,
                    "url": url.absoluteString
                ])
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            var createdSplit = true
            var placementStrategy = "split_right"
            let createdPanel: BrowserPanel?
            if let targetPane = ws.preferredBrowserTargetPane(fromPanelId: sourceSurfaceId) {
                createdPanel = ws.newBrowserSurface(inPane: targetPane, url: url, focus: true)
                createdSplit = false
                placementStrategy = "reuse_right_sibling"
            } else {
                createdPanel = ws.newBrowserSplit(from: sourceSurfaceId, orientation: .horizontal, url: url)
            }

            guard let browserPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create browser", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": browserPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: browserPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "created_split": createdSplit,
                "placement_strategy": placementStrategy
            ])
        }
        return result
    }

    func v2BrowserNavigate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let url = v2String(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            browserPanel.navigateSmart(url)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    nonisolated func v2BrowserBack(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "back")
    }

    nonisolated func v2BrowserForward(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "forward")
    }

    nonisolated func v2BrowserReload(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "reload")
    }

    func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let selectorLiteral = v2JSONLiteral(selector)
        let script = """
        (() => {
          const __selector = \(selectorLiteral);
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = v2NormalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    func v2BrowserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        browserPanel: BrowserPanel
    ) -> V2CallResult {
        var data = v2BrowserNotFoundDiagnostics(surfaceId: surfaceId, browserPanel: browserPanel, selector: selector)
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message: String
        if count > 0 && visibleCount == 0 {
            message = "Element \"\(selector)\" is present but not visible."
        } else if count > 1 {
            message = "Selector \"\(selector)\" matched multiple elements."
        } else {
            message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }

        return .err(code: "not_found", message: message, data: data)
    }

    func v2BrowserAppendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any]
    ) {
        guard v2Bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": v2Bool(params, "snapshot_interactive") ?? true,
            "cursor": v2Bool(params, "snapshot_cursor") ?? false,
            "compact": v2Bool(params, "snapshot_compact") ?? true,
            "max_depth": max(0, v2Int(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = v2String(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = v2OrNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    nonisolated func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: @MainActor @Sendable (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(v2JSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScriptOutcome(
                    browserPanel.webView,
                    surfaceId: surfaceId,
                    script: script,
                    useEval: false
                ) {
                case .frameUnavailable(let frameSelector):
                    return .err(
                        code: "not_found",
                        message: "Selected frame is unavailable",
                        data: ["action": actionName, "selector": selector, "frame_selector": frameSelector]
                    )
                case .failed(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .completed(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ws.id.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard v2WaitForBrowserCondition(
                            browserPanel.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return v2BrowserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                browserPanel: browserPanel
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return v2BrowserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return v2BrowserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                browserPanel: browserPanel
            )
        }
    }

    nonisolated func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    func v2BrowserSnapshotJavaScript(
        interactiveOnly: Bool,
        includeCursor: Bool,
        compact: Bool,
        maxDepth: Int,
        scopeSelector: String?
    ) -> String {
        let boundedMaxDepth = min(Self.v2BrowserSnapshotMaxDepth, max(0, maxDepth))
        let interactiveLiteral = interactiveOnly ? "true" : "false"
        let cursorLiteral = includeCursor ? "true" : "false"
        let compactLiteral = compact ? "true" : "false"
        let scopeLiteral = scopeSelector.map(v2JSONLiteral) ?? "null"
        return """
        (() => {
          const __interactiveOnly = \(interactiveLiteral);
          const __includeCursor = \(cursorLiteral);
          const __compact = \(compactLiteral);
          const __maxDepth = \(boundedMaxDepth);
          const __scopeSelector = \(scopeLiteral);
          const __nodeLimit = \(Self.v2BrowserSnapshotNodeVisitLimit);
          const __entryLimit = \(Self.v2BrowserSnapshotEntryLimit);
          const __selectorByteLimit = \(Self.v2BrowserElementRefSelectorByteLimit);
          const __nameByteLimit = \(Self.v2BrowserSnapshotNameByteLimit);
          const __roleByteLimit = \(Self.v2BrowserSnapshotRoleByteLimit);
          const __entryByteLimit = \(Self.v2BrowserSnapshotEntryByteLimit);
          const __titleByteLimit = \(Self.v2BrowserSnapshotTitleByteLimit);
          const __urlByteLimit = \(Self.v2BrowserSnapshotURLByteLimit);
          const __textLimit = \(Self.v2BrowserSnapshotTextCharacterLimit);
          const __htmlLimit = \(Self.v2BrowserSnapshotHTMLCharacterLimit);
          const __textInspectionLimit = \(Self.v2BrowserSnapshotTextInspectionLimit);
          const __attributeLimit = 4096;
          const __htmlNamespace = 'http://www.w3.org/1999/xhtml';
          const __reasonOrder = ['entry_limit','node_limit','text_inspection_limit','entry_byte_limit','selector_byte_limit','name_byte_limit','role_byte_limit','title_byte_limit','url_byte_limit'];
          const __reasons = new Set();
          const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
          const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
          const __allowedRoles = new Set([...__interactiveRoles, ...__contentRoles, 'application','directory','document','generic','grid','group','list','menu','menubar','none','presentation','row','rowgroup','table','tablist','toolbar','tree','treegrid']);
          const __voidTags = new Set(['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr']);
          const __rawTextTags = new Set(['script','style','xmp','iframe','noembed','noframes','plaintext']);
          const __nonContentTextTags = new Set(['script','style','noscript','template']);

          const __byteWidth = (codePoint) => codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
          const __boundedUTF8 = (input, limit, normalizeWhitespace = false) => {
            const source = String(input == null ? '' : input);
            let value = '';
            let bytes = 0;
            let truncated = false;
            let pendingSpace = false;
            let inspected = 0;
            for (const character of source) {
              inspected += 1;
              if (normalizeWhitespace && inspected > (limit * 4 + 256)) {
                truncated = true;
                break;
              }
              if (normalizeWhitespace && /\\s/u.test(character)) {
                if (value) pendingSpace = true;
                continue;
              }
              const width = __byteWidth(character.codePointAt(0));
              const spaceWidth = pendingSpace ? 1 : 0;
              if (bytes + spaceWidth + width > limit) {
                truncated = true;
                break;
              }
              if (pendingSpace) {
                value += ' ';
                bytes += 1;
                pendingSpace = false;
              }
              value += character;
              bytes += width;
            }
            return { value, bytes, truncated };
          };
          const __htmlLocalName = (element, byteLimit = 64) => {
            if (!element || element.namespaceURI !== __htmlNamespace) return null;
            const bounded = __boundedUTF8(element.localName || '', byteLimit);
            if (!bounded.value || bounded.truncated) return null;
            return bounded.value.toLowerCase();
          };

          const __title = __boundedUTF8(document.title || '', __titleByteLimit);
          const __url = __boundedUTF8(document.location?.href || '', __urlByteLimit);
          if (__title.truncated) __reasons.add('title_byte_limit');
          if (__url.truncated) __reasons.add('url_byte_limit');

          let __root = document.body || document.documentElement;
          let __scoped = false;
          if (__scopeSelector) {
            try {
              const boundedScope = __boundedUTF8(__scopeSelector, __selectorByteLimit);
              if (!boundedScope.truncated && boundedScope.value) {
                const scopedRoot = document.querySelector(boundedScope.value);
                if (scopedRoot) {
                  __root = scopedRoot;
                  __scoped = true;
                }
              }
            } catch (_) {}
          }
          const __serializationRoot = __scoped ? __root : (document.documentElement || __root);
          const __entries = [];
          const __seenSelectors = new Set();
          const __pathByElement = new WeakMap();
          const __elementChildrenSeenByParent = new WeakMap();
          let __entryBytes = 0;
          let __visitedNodes = 0;
          let __workNodes = 0;
          let __nodeBudgetExhausted = false;
          let __selectorSkippedCount = 0;
          let __nameTruncatedCount = 0;
          let __roleSkippedCount = 0;
          let __stop = false;
          let __scopeDepth = __scoped ? 0 : null;
          let __scopeActive = __scoped;

          const __chargeNodeWork = () => {
            if (__workNodes >= __nodeLimit) {
              __nodeBudgetExhausted = true;
              __reasons.add('node_limit');
              return false;
            }
            __workNodes += 1;
            return true;
          };

          let __text = '';
          let __textTruncated = false;
          let __textInspectedUnits = 0;
          let __textInspectionExhausted = false;
          let __textAuthoredWhitespace = false;
          let __textSeparatorRequested = false;
          let __textOutputStopped = false;
          const __markTextInspectionExhausted = () => {
            __textInspectionExhausted = true;
            __textTruncated = true;
            __reasons.add('text_inspection_limit');
          };
          const __inspectTextSource = (value, consume) => {
            if (__textInspectionExhausted || value == null) return { truncated: __textInspectionExhausted, stopped: false };
            const source = String(value);
            let index = 0;
            while (index < source.length) {
              const codePoint = source.codePointAt(index);
              const character = String.fromCodePoint(codePoint);
              const units = character.length;
              if (__textInspectedUnits > __textInspectionLimit - units) {
                __markTextInspectionExhausted();
                return { truncated: true, stopped: false };
              }
              __textInspectedUnits += units;
              index += units;
              if (consume(character) === false) return { truncated: false, stopped: true };
            }
            return { truncated: false, stopped: false };
          };
          const __requestTextSeparator = () => {
            if (__text) __textSeparatorRequested = true;
          };
          const __appendText = (value) => {
            if (__textOutputStopped || __textInspectionExhausted || !value) return;
            __inspectTextSource(value, (character) => {
              if (/\\s/u.test(character)) {
                if (__text) __textAuthoredWhitespace = true;
                return true;
              }
              const needsSpace = __text && (__textAuthoredWhitespace || __textSeparatorRequested);
              const required = character.length + (needsSpace ? 1 : 0);
              if (__text.length > __textLimit - required) {
                __textTruncated = true;
                __textOutputStopped = true;
                return false;
              }
              if (needsSpace) __text += ' ';
              __text += character;
              __textAuthoredWhitespace = false;
              __textSeparatorRequested = false;
              return true;
            });
          };

          let __html = '';
          let __htmlTruncated = false;
          let __htmlStopped = false;
          let __attributeCount = 0;
          const __appendHTML = (value) => {
            if (__htmlStopped || !value) return;
            const remaining = __htmlLimit - __html.length;
            if (remaining <= 0) { __htmlTruncated = true; __htmlStopped = true; return; }
            const source = String(value);
            __html += source.slice(0, remaining);
            if (source.length > remaining) { __htmlTruncated = true; __htmlStopped = true; }
          };
          const __appendEscapedHTML = (value, attribute) => {
            if (__htmlStopped) return;
            const source = String(value == null ? '' : value);
            const remaining = Math.max(0, __htmlLimit - __html.length);
            const probe = source.slice(0, remaining + 1);
            const needsEscaping = attribute ? /[&<>\"]/u.test(probe) : /[&<>]/u.test(probe);
            if (!needsEscaping) {
              __appendHTML(source);
              return;
            }
            for (const character of source) {
              let escaped = character;
              if (character === '&') escaped = '&amp;';
              else if (character === '<') escaped = '&lt;';
              else if (character === '>') escaped = '&gt;';
              else if (attribute && character === '"') escaped = '&quot;';
              __appendHTML(escaped);
              if (__htmlStopped) return;
            }
          };
          const __appendBoundedHTMLName = (rawName, lowercase) => {
            if (__htmlStopped) return;
            const remaining = __htmlLimit - __html.length;
            if (remaining <= 0) { __htmlTruncated = true; __htmlStopped = true; return; }
            const source = String(rawName || '');
            const boundedSource = source.slice(0, remaining + 1);
            __appendHTML(lowercase ? boundedSource.toLowerCase() : boundedSource);
            if (!__htmlStopped && source.length > boundedSource.length) {
              __htmlTruncated = true;
              __htmlStopped = true;
            }
          };
          const __descriptorByElement = new WeakMap();
          const __elementDescriptor = (element) => {
            const cached = __descriptorByElement.get(element);
            if (cached) return cached;
            const isHTML = element.namespaceURI === __htmlNamespace;
            const local = __boundedUTF8(element.localName || '', 64);
            const descriptor = {
              isHTML,
              semanticLocal: isHTML && !local.truncated ? local.value.toLowerCase() : null,
              prefix: element.prefix || '',
              localName: element.localName || ''
            };
            __descriptorByElement.set(element, descriptor);
            return descriptor;
          };
          const __appendElementName = (element) => {
            const descriptor = __elementDescriptor(element);
            if (descriptor.prefix) {
              __appendBoundedHTMLName(descriptor.prefix, false);
              __appendHTML(':');
            }
            __appendBoundedHTMLName(descriptor.localName, descriptor.isHTML);
          };
          const __appendAttributeName = (attribute) => {
            if (attribute.prefix) {
              __appendBoundedHTMLName(attribute.prefix, false);
              __appendHTML(':');
              __appendBoundedHTMLName(attribute.localName, false);
            } else {
              __appendBoundedHTMLName(attribute.name || attribute.localName, false);
            }
          };
          const __appendOpenTag = (element) => {
            if (__htmlStopped) return;
            __appendHTML('<');
            __appendElementName(element);
            if (__htmlStopped) return;
            const attributes = element.attributes;
            for (let index = 0; index < attributes.length; index += 1) {
              if (__attributeCount >= __attributeLimit) {
                __htmlTruncated = true;
                __htmlStopped = true;
                return;
              }
              __attributeCount += 1;
              const attribute = attributes.item(index);
              if (!attribute) continue;
              __appendHTML(' ');
              __appendAttributeName(attribute);
              __appendHTML('=');
              __appendHTML('\"');
              __appendEscapedHTML(attribute.value, true);
              __appendHTML('\"');
              if (__htmlStopped) return;
            }
            __appendHTML('>');
          };
          const __appendCloseTag = (element) => {
            if (__htmlStopped) return;
            const descriptor = __elementDescriptor(element);
            if (descriptor.isHTML && descriptor.semanticLocal && __voidTags.has(descriptor.semanticLocal)) return;
            __appendHTML('<');
            __appendHTML('/');
            __appendElementName(element);
            if (!__htmlStopped) __appendHTML('>');
          };

          const __implicitRole = (element) => {
            const tag = __htmlLocalName(element, 64);
            if (!tag) return null;
            if (tag === 'button' || tag === 'summary') return 'button';
            if (tag === 'a' && element.hasAttribute('href')) return 'link';
            if (tag === 'input') {
              const type = __boundedUTF8(element.getAttribute('type') || 'text', 32, true).value.toLowerCase();
              if (type === 'checkbox') return 'checkbox';
              if (type === 'radio') return 'radio';
              if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
              return 'textbox';
            }
            if (tag === 'textarea') return 'textbox';
            if (tag === 'select') return 'combobox';
            if (/^h[1-6]$/.test(tag)) return 'heading';
            if (tag === 'li') return 'listitem';
            return null;
          };
          const __styleByElement = new WeakMap();
          const __computedStyleFor = (element) => {
            if (__styleByElement.has(element)) return __styleByElement.get(element);
            try {
              const view = element.ownerDocument?.defaultView;
              const style = view?.getComputedStyle ? view.getComputedStyle(element) : null;
              __styleByElement.set(element, style);
              return style;
            } catch (_) {
              __styleByElement.set(element, null);
              return null;
            }
          };
          const __isVisible = (element) => {
            try {
              const style = __computedStyleFor(element);
              const rect = element.getBoundingClientRect();
              return !!style && !!rect && rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0.01;
            } catch (_) { return false; }
          };
          const __cursorEligible = (element) => {
            if (!__includeCursor) return false;
            try {
              const style = __computedStyleFor(element);
              const tabIndex = element.getAttribute('tabindex');
              return typeof element.onclick === 'function' || element.hasAttribute('onclick') || style?.cursor === 'pointer' || (tabIndex != null && String(tabIndex) !== '-1');
            } catch (_) { return false; }
          };
          const __isRenderedBlock = (element) => {
            const tag = __htmlLocalName(element, 64);
            if (tag === 'br') return true;
            const display = __computedStyleFor(element)?.display || '';
            return !!display && display !== 'none' && display !== 'contents' && !display.startsWith('inline');
          };
          const __isOwnTextSuppressed = (element, ignoreHidden = false) => {
            const tag = __htmlLocalName(element, 64);
            if (tag && __nonContentTextTags.has(tag)) return true;
            if (ignoreHidden) return false;
            if (element.hidden || element.hasAttribute('hidden')) return true;
            const ariaHidden = __boundedUTF8(element.getAttribute('aria-hidden') || '', 16, true).value.toLowerCase();
            if (ariaHidden === 'true') return true;
            const style = __computedStyleFor(element);
            return style?.display === 'none' || style?.visibility === 'hidden' || style?.visibility === 'collapse';
          };
          const __templateHostByContent = new WeakMap();
          const __textSuppressedByElement = new WeakMap();
          const __updateTextSuppression = (element) => {
            const domParent = element.parentNode;
            const logicalParent = __templateHostByContent.get(domParent) || domParent;
            const parentSuppressed = logicalParent ? (__textSuppressedByElement.get(logicalParent) || false) : false;
            const suppressed = parentSuppressed || __isOwnTextSuppressed(element);
            __textSuppressedByElement.set(element, suppressed);
            return suppressed;
          };

          const __createNameSink = () => ({
            value: '', bytes: 0, pendingWhitespace: false, separatorRequested: false,
            truncated: false, stopped: false
          });
          const __appendNameCharacter = (sink, character) => {
            if (sink.stopped) return false;
            if (/\\s/u.test(character)) {
              if (sink.value) sink.pendingWhitespace = true;
              return true;
            }
            const needsSpace = sink.value && (sink.pendingWhitespace || sink.separatorRequested);
            const width = __byteWidth(character.codePointAt(0));
            const required = width + (needsSpace ? 1 : 0);
            if (sink.bytes > __nameByteLimit - required) {
              sink.truncated = true;
              sink.stopped = true;
              return false;
            }
            if (needsSpace) { sink.value += ' '; sink.bytes += 1; }
            sink.value += character;
            sink.bytes += width;
            sink.pendingWhitespace = false;
            sink.separatorRequested = false;
            return true;
          };
          const __appendNameSource = (sink, value) => {
            if (sink.stopped || !value) return;
            const inspected = __inspectTextSource(value, (character) => __appendNameCharacter(sink, character));
            if (inspected.truncated) return;
          };
          const __mergeNameValue = (sink, result) => {
            if (!result.value) {
              if (result.truncated) sink.truncated = true;
              return;
            }
            if (sink.value) sink.separatorRequested = true;
            for (const character of result.value) {
              if (!__appendNameCharacter(sink, character)) break;
            }
            if (result.truncated) sink.truncated = true;
          };
          const __nameContentCache = new WeakMap();
          const __explicitLabelContentCache = new WeakMap();
          const __walkNameContent = (root, includeHiddenSubtree) => {
            const cache = includeHiddenSubtree ? __explicitLabelContentCache : __nameContentCache;
            const cached = cache.get(root);
            if (cached) return cached;
            const sink = __createNameSink();
            const suppressedByElement = new WeakMap();
            let node = root;
            while (node) {
              if (!__chargeNodeWork()) break;
              let suppressed = false;
              if (node.nodeType === Node.ELEMENT_NODE) {
                const parentSuppressed = node === root ? false : (suppressedByElement.get(node.parentElement) || false);
                suppressed = parentSuppressed || __isOwnTextSuppressed(node, includeHiddenSubtree);
                suppressedByElement.set(node, suppressed);
                if (!suppressed && __isRenderedBlock(node)) sink.separatorRequested = !!sink.value;
              } else if (node.nodeType === Node.TEXT_NODE) {
                suppressed = suppressedByElement.get(node.parentElement) || false;
                if (!suppressed) __appendNameSource(sink, node.nodeValue || '');
              }

              const descend = node.nodeType === Node.ELEMENT_NODE && !suppressed && !!node.firstChild;
              if (descend) {
                node = node.firstChild;
                continue;
              }
              while (node) {
                if (node.nodeType === Node.ELEMENT_NODE
                    && !(suppressedByElement.get(node) || false)
                    && __isRenderedBlock(node)
                    && sink.value) {
                  sink.separatorRequested = true;
                }
                if (node === root) { node = null; break; }
                if (node.nextSibling) { node = node.nextSibling; break; }
                node = node.parentNode;
              }
            }
            const result = { value: sink.value, bytes: sink.bytes, truncated: sink.truncated };
            cache.set(root, result);
            return result;
          };
          const __boundedNameSource = (value) => __boundedUTF8(value || '', __nameByteLimit, true);
          const __nameFor = (element) => {
            let result = null;
            let discoveryTruncated = false;
            const labelledBy = __boundedUTF8(element.getAttribute('aria-labelledby') || '', 256, true);
            if (labelledBy.value) {
              const combined = __createNameSink();
              const resolvedLabels = new Set();
              let count = 0;
              for (const id of labelledBy.value.split(' ')) {
                if (!id) continue;
                if (count >= 16) { combined.truncated = true; break; }
                count += 1;
                const labelled = element.ownerDocument?.getElementById(id);
                if (!labelled || resolvedLabels.has(labelled)) continue;
                resolvedLabels.add(labelled);
                __mergeNameValue(combined, __walkNameContent(labelled, true));
                if (combined.stopped || __nodeBudgetExhausted) break;
              }
              discoveryTruncated = labelledBy.truncated || combined.truncated;
              if (combined.value) result = { value: combined.value, bytes: combined.bytes, truncated: combined.truncated };
            } else {
              discoveryTruncated = labelledBy.truncated;
            }
            if (!result) {
              const ariaLabel = __boundedNameSource(element.getAttribute('aria-label') || '');
              if (ariaLabel.value) result = ariaLabel;
              discoveryTruncated = discoveryTruncated || ariaLabel.truncated;
            }
            const tag = __htmlLocalName(element, 64);
            if (!result && (tag === 'input' || tag === 'textarea')) {
              const hostName = __boundedNameSource(element.getAttribute('placeholder') || element.value || '');
              if (hostName.value) result = hostName;
              discoveryTruncated = discoveryTruncated || hostName.truncated;
            }
            if (!result) {
              const titleName = __boundedNameSource(element.getAttribute('title') || '');
              if (titleName.value) result = titleName;
              discoveryTruncated = discoveryTruncated || titleName.truncated;
            }
            if (!result) result = __walkNameContent(element, false);
            if (result.truncated || discoveryTruncated) {
              __nameTruncatedCount += 1;
              __reasons.add('name_byte_limit');
            }
            return result;
          };

          const __buildScopedRootPath = (element) => {
            const documentElement = element.ownerDocument?.documentElement;
            let current = element;
            let suffix = '';
            while (current) {
              if (!__chargeNodeWork()) return null;
              if (current === documentElement) {
                const complete = __boundedUTF8(':root' + suffix, __selectorByteLimit);
                return complete.truncated ? null : complete.value;
              }
              const parent = current.parentElement;
              if (!parent) return null;
              let ordinal = 1;
              let sibling = current.previousElementSibling;
              while (sibling) {
                if (!__chargeNodeWork()) return null;
                ordinal += 1;
                sibling = sibling.previousElementSibling;
              }
              const candidate = ' > :nth-child(' + ordinal + ')' + suffix;
              if (__boundedUTF8(candidate, __selectorByteLimit).truncated) return null;
              suffix = candidate;
              current = parent;
            }
            return null;
          };
          let __scopedPathAvailable = !__scoped;
          if (__scoped) {
            const scopedPath = __buildScopedRootPath(__root);
            if (scopedPath) {
              __pathByElement.set(__root, scopedPath);
              __scopedPathAvailable = true;
            }
          }
          const __recordStructuralPath = (element) => {
            const existing = __pathByElement.get(element);
            if (existing) return existing;
            if (__scoped && element === __root && !__scopedPathAvailable) return null;
            if (element === element.ownerDocument?.documentElement) {
              __pathByElement.set(element, ':root');
              return ':root';
            }
            const parent = element.parentElement;
            if (!parent) return null;
            const ordinal = (__elementChildrenSeenByParent.get(parent) || 0) + 1;
            __elementChildrenSeenByParent.set(parent, ordinal);
            const parentPath = __pathByElement.get(parent);
            if (!parentPath) return null;
            const candidate = parentPath + ' > :nth-child(' + ordinal + ')';
            const bounded = __boundedUTF8(candidate, __selectorByteLimit);
            if (bounded.truncated) return null;
            __pathByElement.set(element, bounded.value);
            return bounded.value;
          };
          const __selectorFor = (element) => {
            const structural = __pathByElement.get(element) || null;
            const rawId = element.id || '';
            if (rawId) {
              const rawBound = __boundedUTF8(rawId, __selectorByteLimit);
              if (rawBound.truncated) return { selector: null, oversized: true };
              try {
                const escapedValue = __boundedUTF8(CSS.escape(rawBound.value), __selectorByteLimit - 1);
                if (escapedValue.truncated) return { selector: null, oversized: true };
                const escaped = '#' + escapedValue.value;
                if (element.ownerDocument?.querySelector(escaped) === element) {
                  return { selector: escaped, oversized: false };
                }
              } catch (_) {}
            }
            return { selector: structural, oversized: !structural };
          };

          const __appendEntry = (element, depth) => {
            if (!__isVisible(element)) return;
            const cursorEligible = __cursorEligible(element);
            const explicitRaw = element.getAttribute('role') || '';
            const explicitBounded = __boundedUTF8(explicitRaw, __roleByteLimit, true);
            const explicitValue = explicitBounded.value.toLowerCase();
            const explicitRole = !explicitBounded.truncated && __allowedRoles.has(explicitValue) ? explicitValue : null;
            const implicitRole = __implicitRole(element);
            let role = explicitRole || implicitRole || (cursorEligible ? 'generic' : null);
            if (!role) {
              if (explicitRaw) { __roleSkippedCount += 1; __reasons.add('role_byte_limit'); }
              return;
            }
            if (__interactiveOnly && !__interactiveRoles.has(role) && !cursorEligible) return;
            if (!__interactiveOnly && !__interactiveRoles.has(role) && !__contentRoles.has(role) && !cursorEligible) return;
            const selectorResult = __selectorFor(element);
            if (!selectorResult.selector) {
              if (selectorResult.oversized) { __selectorSkippedCount += 1; __reasons.add('selector_byte_limit'); }
              return;
            }
            const name = __nameFor(element);
            if (__compact && role === 'generic' && !name.value) return;
            const selector = selectorResult.selector;
            if (__seenSelectors.has(selector)) return;
            if (__entries.length >= __entryLimit) { __reasons.add('entry_limit'); __stop = true; return; }
            const candidateBytes = __boundedUTF8(selector, __selectorByteLimit).bytes + name.bytes + __boundedUTF8(role, __roleByteLimit).bytes;
            if (candidateBytes > __entryByteLimit - __entryBytes) { __reasons.add('entry_byte_limit'); __stop = true; return; }
            __seenSelectors.add(selector);
            __entryBytes += candidateBytes;
            __entries.push({ selector, role, name: name.value, depth });
          };

          const __firstTraversalChild = (node) => {
            if (node.nodeType === Node.ELEMENT_NODE) {
              const descriptor = __elementDescriptor(node);
              if (descriptor.isHTML && descriptor.semanticLocal === 'template') {
                const content = node.content;
                if (content) {
                  __templateHostByContent.set(content, node);
                  __textSuppressedByElement.set(
                    content,
                    __textSuppressedByElement.get(node) || false
                  );
                  return content.firstChild;
                }
              }
            }
            return node.firstChild;
          };
          const __traversalParent = (node) => {
            const domParent = node.parentNode;
            return __templateHostByContent.get(domParent) || domParent;
          };

          let __node = __serializationRoot;
          let __depth = 0;
          while (__node && !__stop) {
            if (!__chargeNodeWork()) {
              __textTruncated = true;
              __htmlTruncated = true;
              break;
            }
            __visitedNodes += 1;
            const isElement = __node.nodeType === Node.ELEMENT_NODE;
            if (__node === __root) {
              __scopeDepth = __depth;
              __scopeActive = true;
            }
            const inScope = __scopeActive;
            const relativeDepth = __scopeDepth == null ? 0 : __depth - __scopeDepth;
            let textSuppressed = false;
            if (isElement) {
              textSuppressed = __updateTextSuppression(__node);
              __appendOpenTag(__node);
              __recordStructuralPath(__node);
            }
            else if (__node.nodeType === Node.TEXT_NODE) {
              const parentDescriptor = __node.parentElement ? __elementDescriptor(__node.parentElement) : null;
              if (parentDescriptor?.isHTML
                  && parentDescriptor.semanticLocal
                  && __rawTextTags.has(parentDescriptor.semanticLocal)) {
                __appendHTML(__node.nodeValue || '');
              }
              else __appendEscapedHTML(__node.nodeValue || '', false);
            } else if (__node.nodeType === Node.COMMENT_NODE) {
              __appendHTML('<!--');
              __appendHTML(__node.nodeValue || '');
              __appendHTML('-->');
            }

            if (inScope) {
              if (isElement && !textSuppressed) {
                if (__isRenderedBlock(__node)) __requestTextSeparator();
              }
              if (__node.nodeType === Node.TEXT_NODE) {
                const domParent = __node.parentNode;
                const parent = __templateHostByContent.get(domParent) || domParent;
                if (!parent || !(__textSuppressedByElement.get(parent) || false)) {
                  __appendText(__node.nodeValue || '');
                }
              }
              if (isElement && relativeDepth <= __maxDepth) __appendEntry(__node, relativeDepth);
              if (__stop || __nodeBudgetExhausted) {
                __textTruncated = true;
                __htmlTruncated = true;
                break;
              }
            }

            const firstChild = __firstTraversalChild(__node);
            let descend = !!firstChild;
            if (inScope && relativeDepth >= __maxDepth && descend) {
              descend = false;
              __textTruncated = true;
              __htmlTruncated = true;
              __htmlStopped = true;
            }
            if (descend) {
              __node = firstChild;
              __depth += 1;
              continue;
            }
            while (__node) {
              if (__node.nodeType === Node.ELEMENT_NODE) {
                const closingSuppressed = __textSuppressedByElement.get(__node) || false;
                if (__scopeActive && !closingSuppressed && __isRenderedBlock(__node)) {
                  __requestTextSeparator();
                }
                __appendCloseTag(__node);
                if (__node === __root) __scopeActive = false;
              }
              if (__node === __serializationRoot) { __node = null; break; }
              if (__node.nextSibling) { __node = __node.nextSibling; break; }
              __node = __traversalParent(__node);
              __depth -= 1;
            }
          }

          const __truncationReasons = __reasonOrder.filter((reason) => __reasons.has(reason));
          return {
            title: __title.value,
            url: __url.value,
            ready_state: String(document.readyState || ''),
            text: __text,
            html: __html,
            entries: __entries,
            truncated: __truncationReasons.length > 0 || __textTruncated || __htmlTruncated,
            truncation_reasons: __truncationReasons,
            element_limit: __entryLimit,
            node_limit: __nodeLimit,
            visited_nodes: __visitedNodes,
            text_inspection_limit: __textInspectionLimit,
            text_inspected_units: __textInspectedUnits,
            entry_byte_limit: __entryByteLimit,
            entry_bytes: __entryBytes,
            selector_byte_limit: __selectorByteLimit,
            selector_skipped_count: __selectorSkippedCount,
            name_byte_limit: __nameByteLimit,
            name_truncated_count: __nameTruncatedCount,
            role_byte_limit: __roleByteLimit,
            role_skipped_count: __roleSkippedCount,
            title_byte_limit: __titleByteLimit,
            url_byte_limit: __urlByteLimit,
            text_truncated: __textTruncated,
            html_truncated: __htmlTruncated
          };
        })()
        """
    }

    func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = min(64, max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12))
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let script = v2BrowserSnapshotJavaScript(
                interactiveOnly: interactiveOnly,
                includeCursor: includeCursor,
                compact: compact,
                maxDepth: maxDepth,
                scopeSelector: scopeSelector
            )

            let dict: [String: Any]
            switch v2BrowserCollectSnapshotJavaScriptOutcome(
                webView: browserPanel.webView,
                surfaceId: surfaceId,
                script: script
            ) {
            case .collected(let value):
                dict = value
            case .frameUnavailable(let selector):
                return .err(
                    code: "not_found",
                    message: "Selected browser frame is unavailable",
                    data: [
                        "surface_id": surfaceId.uuidString,
                        "frame_selector": selector
                    ]
                )
            case .failed(let message):
                return .err(
                    code: "js_error",
                    message: "Browser snapshot collection failed",
                    data: ["details": message]
                )
            }

                let readyState = (dict["ready_state"] as? String) ?? ""
                let snapshotContent = v2BrowserPostProcessSnapshotResult(dict)
                let title = snapshotContent.title
                let url = snapshotContent.url
                let text = snapshotContent.text
                let html = snapshotContent.html
                let boundedEntries = snapshotContent.entries

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                let selectors = boundedEntries.compactMap { $0["selector"] as? String }
                let allocatedRefs: [String]
                switch browserRPCState.allocateElementRefs(surfaceId: surfaceId, selectors: selectors) {
                case .allocated(let values):
                    allocatedRefs = values
                case .resourceExhausted(let capacity):
                    return v2BrowserElementRefResourceExhaustedResult(surfaceId: surfaceId, capacity: capacity)
                }

                for (entry, refToken) in zip(boundedEntries, allocatedRefs) {
                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                for (key, value) in snapshotContent.metadata {
                    payload[key] = value
                }
                return .ok(payload)
        }
    }

    func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = v2BrowserSelector(params)

        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                let literal = v2JSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = v2String(params, "text_contains") {
                let literal = v2JSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = v2JSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = v2String(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        var setupResult: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var webView: WKWebView?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupResult = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupResult = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                setupResult = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                setupResult = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            workspaceId = ws.id
            surfaceIdOut = surfaceId
            webView = browserPanel.webView
        }

        if let setupResult {
            return setupResult
        }
        guard let workspaceId, let surfaceIdOut, let webView else {
            return .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceIdOut)
            }
            let literal = v2JSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        if v2WaitForBrowserCondition(
            webView,
            surfaceId: surfaceIdOut,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "waited": true
            ])
        }
        return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
    }

    nonisolated func v2BrowserClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "click") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof el.click === 'function') {
                el.click();
              } else {
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
              }
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserDblClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window, detail: 2 }));
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserHover(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
              el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserFocusElement(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "focus") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              return { ok: true };
            })()
            """
        }
    }

    /// JavaScript snippet that sets an input element's value using the native
    /// prototype setter. Frameworks like React, Vue, and Angular override the
    /// value property on instances, so a plain `el.value = x` assignment only
    /// updates the DOM without notifying the framework's internal state.
    /// Calling the native setter from the prototype bypasses the override and
    /// triggers the framework's change-detection when followed by an `input`
    /// event. Walks the prototype chain instead of using instanceof so it
    /// works with cross-realm elements (iframes) and custom web components.
    /// Expects `el` and `newValue` to be in scope.
    private static let reactCompatibleSetValue = """
        let nativeSetter = null;
        for (let proto = Object.getPrototypeOf(el); proto; proto = Object.getPrototypeOf(proto)) {
          const desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) { nativeSetter = desc.set; break; }
        }
        if (nativeSetter) {
          nativeSetter.call(el, newValue);
        } else {
          el.value = newValue;
        }
    """

    nonisolated func v2BrowserType(params: [String: Any]) -> V2CallResult {
        guard let text = v2String(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "type") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const chunk = String(\(textLiteral));
              if ('value' in el) {
                const newValue = (el.value || '') + chunk;
                \(Self.reactCompatibleSetValue)
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = (el.textContent || '') + chunk;
              }
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserFill(params: [String: Any]) -> V2CallResult {
        // `fill` must allow empty strings so callers can clear existing input values.
        guard let text = v2RawString(params, "text") ?? v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing text/value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "fill") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const newValue = String(\(textLiteral));
              if ('value' in el) {
                \(Self.reactCompatibleSetValue)
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = newValue;
              }
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserPress(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keypress', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    nonisolated func v2BrowserKeyDown(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    nonisolated func v2BrowserKeyUp(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    nonisolated func v2BrowserCheck(params: [String: Any], checked: Bool) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
              el.checked = \(checked ? "true" : "false");
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserSelect(params: [String: Any]) -> V2CallResult {
        let selectedValue = v2String(params, "value") ?? v2String(params, "text")
        guard let selectedValue else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "select") { selectorLiteral in
            let valueLiteral = v2JSONLiteral(selectedValue)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('value' in el)) return { ok: false, error: 'not_select' };
              const newValue = String(\(valueLiteral));
              \(Self.reactCompatibleSetValue)
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    nonisolated func v2BrowserScroll(params: [String: Any]) -> V2CallResult {
        let dx = v2Int(params, "dx") ?? 0
        let dy = v2Int(params, "dy") ?? 0
        let selectorRaw = v2BrowserSelector(params)

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let selector = selectorRaw.flatMap { v2BrowserResolveSelector($0, surfaceId: surfaceId) }
            if let selectorRaw, selector == nil {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }

            let script: String
            if let selector {
                let selectorLiteral = v2JSONLiteral(selector)
                script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.scrollBy === 'function') {
                    el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
                  } else {
                    el.scrollLeft += \(dx);
                    el.scrollTop += \(dy);
                  }
                  return { ok: true };
                })()
                """
            } else {
                script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
            }

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return v2BrowserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    nonisolated func v2BrowserScrollIntoView(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "scroll_into_view") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true };
            })()
            """
        }
    }

#if DEBUG
    private nonisolated func v2BrowserScreenshotDebugGate(
        params: [String: Any]
    ) -> V2BrowserScreenshotDebugGate? {
        guard let pendingMarkerPath = v2String(params, "_test_screenshot_pending_marker_path"),
              let releaseMarkerPath = v2String(params, "_test_screenshot_release_marker_path") else {
            return nil
        }
        let standardizedPendingPath = URL(fileURLWithPath: pendingMarkerPath).standardizedFileURL.path
        let standardizedReleasePath = URL(fileURLWithPath: releaseMarkerPath).standardizedFileURL.path
        guard standardizedPendingPath != standardizedReleasePath else { return nil }
        return V2BrowserScreenshotDebugGate(
            pendingMarkerPath: standardizedPendingPath,
            releaseMarkerPath: standardizedReleasePath
        )
    }
#endif

    private nonisolated static func v2BrowserRouteScreenshotCapture(
        _ outcome: V2BrowserScreenshotCaptureOutcome,
        state: V2BrowserScreenshotWaitState,
        debugGate: V2BrowserScreenshotDebugGate?
    ) {
#if DEBUG
        if let debugGate {
            let queue = DispatchQueue(label: "com.darkroom.programa.browser-screenshot-test-gate", qos: .utility)
            queue.async {
                let markerBytes = Array("pending".utf8)
                let markerDescriptor = debugGate.pendingMarkerPath.withCString {
                    Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
                }
                guard markerDescriptor >= 0 else {
                    state.complete(outcome)
                    return
                }

                let wroteAllBytes = markerBytes.withUnsafeBytes { buffer -> Bool in
                    guard let baseAddress = buffer.baseAddress else { return false }
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(
                            markerDescriptor,
                            baseAddress.advanced(by: offset),
                            buffer.count - offset
                        )
                        if written > 0 {
                            offset += written
                        } else if written < 0, errno == EINTR {
                            continue
                        } else {
                            return false
                        }
                    }
                    return true
                }
                let closedSuccessfully = Darwin.close(markerDescriptor) == 0
                guard wroteAllBytes, closedSuccessfully else {
                    state.complete(outcome)
                    return
                }

                let safetyDeadline = ProcessInfo.processInfo.systemUptime + 8.0
                while ProcessInfo.processInfo.systemUptime < safetyDeadline,
                      !Self.v2BrowserDownloadPathIsReady(debugGate.releaseMarkerPath) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                state.complete(outcome)
            }
            return
        }
#endif
        state.complete(outcome)
    }

    nonisolated func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult {
#if DEBUG
        let debugGate = v2BrowserScreenshotDebugGate(params: params)
#else
        let debugGate: V2BrowserScreenshotDebugGate? = nil
#endif
        let state = V2BrowserScreenshotWaitState()
        let startOutcome: V2BrowserScreenshotStartOutcome = v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .failed(.tabManagerUnavailable)
            }
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .failed(.workspaceNotFound)
            }
            let surfaceId = v2UUID(params, "surface_id") ?? workspace.focusedPanelId
            guard let surfaceId else {
                return .failed(.noFocusedSurface)
            }
            guard let browserPanel = workspace.browserPanel(for: surfaceId) else {
                return .failed(.surfaceNotBrowser(surfaceId))
            }

            browserPanel.takeSnapshot { image in
                let captureOutcome: V2BrowserScreenshotCaptureOutcome
                if let image, let imageData = Self.v2PNGData(from: image) {
                    captureOutcome = .captured(imageData)
                } else {
                    captureOutcome = .failed
                }
                Self.v2BrowserRouteScreenshotCapture(
                    captureOutcome,
                    state: state,
                    debugGate: debugGate
                )
            }
            return .started(V2BrowserScreenshotContext(workspaceId: workspace.id, surfaceId: surfaceId))
        }

        let context: V2BrowserScreenshotContext
        switch startOutcome {
        case .started(let startedContext):
            context = startedContext
        case .failed(.tabManagerUnavailable):
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .failed(.workspaceNotFound):
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .failed(.noFocusedSurface):
            return .err(code: "not_found", message: "No focused browser surface", data: nil)
        case .failed(.surfaceNotBrowser(let surfaceId)):
            return .err(
                code: "invalid_params",
                message: "Surface is not a browser",
                data: ["surface_id": surfaceId.uuidString]
            )
        }

        let imageData: Data
        switch state.wait(timeout: 5.0) {
        case .captured(let capturedData):
            imageData = capturedData
        case .failed:
            return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
        case .timedOut:
            return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
        }

        var result: [String: Any] = [
            "workspace_id": context.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
            "surface_id": context.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
            "png_base64": imageData.base64EncodedString()
        ]

        // Best effort: keep screenshot data available even when temp-file writes fail.
        let screenshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
            Self.bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortSurfaceId = String(context.surfaceId.uuidString.prefix(8))
            let shortRandomId = String(UUID().uuidString.prefix(8))
            let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
            let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
            if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                result["path"] = imageURL.path
                result["url"] = imageURL.absoluteString
            }
        }

        return .ok(result)
    }

    nonisolated func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    nonisolated func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    nonisolated func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    nonisolated func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = v2JSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    nonisolated func v2BrowserGetTitle(params: [String: Any]) -> V2CallResult {
        v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "title": browserPanel.pageTitle
            ])
        }
    }

    nonisolated func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(
                browserPanel.webView,
                surfaceId: surfaceId,
                script: script,
                useEval: false
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    nonisolated func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    nonisolated func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = v2JSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

    nonisolated func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    nonisolated func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    nonisolated func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }


    nonisolated func v2BrowserNavSimple(params: [String: Any], action: String) -> V2CallResult {
        return v2MainSync { () -> V2CallResult in
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let surfaceId = v2UUID(params, "surface_id") else {
                return v2InvalidParam("surface_id")
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else {
                return .err(
                    code: "not_found",
                    message: "Surface not found or not a browser",
                    data: ["surface_id": surfaceId.uuidString]
                )
            }
            switch action {
            case "back":
                browserPanel.goBack()
            case "forward":
                browserPanel.goForward()
            case "reload":
                browserPanel.reload()
            default:
                break
            }
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            return .ok(payload)
        }
    }

    nonisolated func v2BrowserGetURL(params: [String: Any]) -> V2CallResult {
        return v2MainSync { () -> V2CallResult in
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let surfaceId = v2UUID(params, "surface_id") else {
                return v2InvalidParam("surface_id")
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else {
                return .err(
                    code: "not_found",
                    message: "Surface not found or not a browser",
                    data: ["surface_id": surfaceId.uuidString]
                )
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "url": browserPanel.currentURL?.absoluteString ?? ""
            ])
        }
    }

    func v2BrowserFocusWebView(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.0)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = .err(code: "invalid_state", message: "WebView is not in a window", data: nil)
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = .err(code: "invalid_state", message: "WebView is hidden", data: nil)
                return
            }

            window.makeFirstResponder(webView)
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                result = .ok(["focused": true])
            } else {
                result = .err(code: "internal_error", message: "Focus did not move into web view", data: nil)
            }
        }
        return result
    }

    /// Toggles Design Mode using the shared focused-panel routing rule
    /// (`resolveDesignModeShortcutRoute` / `activateDesignModeRoute`): no `surface_id` required, targets the
    /// focused browser panel directly, or the workspace's single browser panel when a terminal is
    /// focused.
    func v2BrowserDesignModeToggle(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .err(
            code: "not_found",
            message: "No browser panel available for Design Mode",
            data: nil
        )
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            if activateDesignModeRoute(in: ws) {
                result = .ok(["toggled": true])
            }
        }
        return result
    }

    func v2BrowserIsWebViewFocused(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        var focused = false
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            let webView = browserPanel.webView
            guard let window = webView.window,
                  let fr = window.firstResponder as? NSView else {
                focused = false
                return
            }
            focused = fr.isDescendant(of: webView)
        }
        return .ok(["focused": focused])
    }

    private nonisolated static let v2BrowserCssPathScript = """
    const __programaCssPath = (el) => {
      if (!el || el.nodeType !== 1) return null;
      try {
        const parts = [];
        let cur = el;
        while (cur && cur.nodeType === 1) {
          if (cur.id) {
            const idSelector = '#' + CSS.escape(cur.id);
            const matches = document.querySelectorAll(idSelector);
            if (matches.length === 1 && matches[0] === cur) {
              parts.unshift(idSelector);
              break;
            }
          }
          const tag = String(cur.localName || cur.tagName || '');
          if (!tag) return null;
          let part = CSS.escape(tag);
          const siblings = cur.parentElement
            ? Array.from(cur.parentElement.children).filter((n) =>
                n.localName === cur.localName && n.namespaceURI === cur.namespaceURI)
            : [];
          if (siblings.length > 1) {
            part += `:nth-of-type(${siblings.indexOf(cur) + 1})`;
          }
          parts.unshift(part);
          cur = cur.parentElement;
        }
        const path = parts.join(' > ');
        return path && document.querySelector(path) === el ? path : null;
      } catch {
        return null;
      }
    };
    """

    nonisolated func v2BrowserFindWithScript(
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadataBuilder: @MainActor @Sendable () -> [String: Any] = { [:] }
    ) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let metadata = metadataBuilder()
            let script = """
            (() => {
              \(Self.v2BrowserCssPathScript)

              const __programaFound = (() => {
            \(finderBody)
              })();
              if (!__programaFound) return { ok: false, error: 'not_found' };
              const selector = __programaCssPath(__programaFound);
              if (!selector) return { ok: false, error: 'not_found' };
              return {
                ok: true,
                selector,
                tag: String(__programaFound.tagName || '').toLowerCase(),
                text: String(__programaFound.textContent || '').trim()
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: ["action": actionName])
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: metadata)
                }

                return v2BrowserWithAllocatedElementRef(surfaceId: surfaceId, selector: selector) { ref in
                    var payload: [String: Any] = [
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "action": actionName,
                        "selector": selector,
                        "element_ref": ref,
                        "ref": ref
                    ]
                    for (k, v) in metadata {
                        payload[k] = v
                    }
                    if let tag = dict["tag"] as? String {
                        payload["tag"] = tag
                    }
                    if let text = dict["text"] as? String {
                        payload["text"] = text
                    }
                    return .ok(payload)
                }
            }
        }
    }

    nonisolated func v2BrowserFindRole(params: [String: Any]) -> V2CallResult {
        guard let role = (v2String(params, "role") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = v2String(params, "name")?.lowercased()
        let exact = v2Bool(params, "exact") ?? false
        let roleLiteral = v2JSONLiteral(role)
        let nameLiteral = name.map(v2JSONLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __targetRole = String(\(roleLiteral)).toLowerCase();
                const __targetName = \(nameLiteral);
                const __exact = \(exactLiteral);
                const __implicitRole = (el) => {
                  const tag = String(el.tagName || '').toLowerCase();
                  if (tag === 'button') return 'button';
                  if (tag === 'a' && el.hasAttribute('href')) return 'link';
                  if (tag === 'input') {
                    const type = String(el.getAttribute('type') || 'text').toLowerCase();
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit' || type === 'button') return 'button';
                    return 'textbox';
                  }
                  if (tag === 'textarea') return 'textbox';
                  if (tag === 'select') return 'combobox';
                  return null;
                };
                const __nameFor = (el) => {
                  const aria = String(el.getAttribute('aria-label') || '').trim();
                  if (aria) return aria.toLowerCase();
                  const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                  if (labelledBy) {
                    const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                    if (text) return text.toLowerCase();
                  }
                  const txt = String(el.innerText || el.textContent || '').trim();
                  if (txt) return txt.toLowerCase();
                  if ('value' in el) {
                    const v = String(el.value || '').trim();
                    if (v) return v.toLowerCase();
                  }
                  return '';
                };
                const __nodes = Array.from(document.querySelectorAll('*'));
                return __nodes.find((el) => {
                  const explicit = String(el.getAttribute('role') || '').toLowerCase();
                  const resolved = explicit || __implicitRole(el) || '';
                  if (resolved !== __targetRole) return false;
                  if (__targetName == null) return true;
                  const currentName = __nameFor(el);
                  return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.role",
            finderBody: finder,
            metadataBuilder: {
                [
                    "role": role,
                    "name": v2OrNull(name),
                    "exact": exact
                ]
            }
        )
    }

    nonisolated func v2BrowserFindText(params: [String: Any]) -> V2CallResult {
        guard let text = (v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let textLiteral = v2JSONLiteral(text)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(textLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __nodes = Array.from(document.querySelectorAll('body *'));
                return __nodes.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  if (!v) return false;
                  return __exact ? (v === __target) : v.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.text",
            finderBody: finder,
            metadataBuilder: { ["text": text, "exact": exact] }
        )
    }

    nonisolated func v2BrowserFindLabel(params: [String: Any]) -> V2CallResult {
        guard let label = (v2String(params, "label") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let labelLiteral = v2JSONLiteral(label)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(labelLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __labels = Array.from(document.querySelectorAll('label'));
                const __label = __labels.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  return __exact ? (v === __target) : v.includes(__target);
                });
                if (!__label) return null;
                const htmlFor = String(__label.getAttribute('for') || '').trim();
                if (htmlFor) {
                  return document.getElementById(htmlFor);
                }
                return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.label",
            finderBody: finder,
            metadataBuilder: { ["label": label, "exact": exact] }
        )
    }

    nonisolated func v2BrowserFindPlaceholder(params: [String: Any]) -> V2CallResult {
        guard let placeholder = (v2String(params, "placeholder") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let placeholderLiteral = v2JSONLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadataBuilder: { ["placeholder": placeholder, "exact": exact] }
        )
    }

    nonisolated func v2BrowserFindAlt(params: [String: Any]) -> V2CallResult {
        guard let alt = (v2String(params, "alt") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let altLiteral = v2JSONLiteral(alt)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.alt",
            finderBody: finder,
            metadataBuilder: { ["alt": alt, "exact": exact] }
        )
    }

    nonisolated func v2BrowserFindTitle(params: [String: Any]) -> V2CallResult {
        guard let title = (v2String(params, "title") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let titleLiteral = v2JSONLiteral(title)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.title",
            finderBody: finder,
            metadataBuilder: { ["title": title, "exact": exact] }
        )
    }

    nonisolated func v2BrowserFindTestId(params: [String: Any]) -> V2CallResult {
        guard let testId = v2String(params, "testid") ?? v2String(params, "test_id") ?? v2String(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let testIdLiteral = v2JSONLiteral(testId)

        let finder = """
                const __target = String(\(testIdLiteral));
                const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                for (const sel of __selectors) {
                  const nodes = Array.from(document.querySelectorAll(sel));
                  const found = nodes.find((el) => {
                    return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                  });
                  if (found) return found;
                }
                return null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.testid",
            finderBody: finder,
            metadataBuilder: { ["testid": testId] }
        )
    }

    nonisolated func v2BrowserFindFirst(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                return v2BrowserWithAllocatedElementRef(surfaceId: surfaceId, selector: selector) { ref in
                    .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "selector": selector,
                        "element_ref": ref,
                        "ref": ref,
                        "text": v2OrNull(dict["text"])
                    ])
                }
            }
        }
    }

    nonisolated func v2BrowserFindLast(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = document.querySelectorAll(\(selectorLiteral));
              if (!list || list.length === 0) return { ok: false, error: 'not_found' };
              const idx = list.length - 1;
              const el = list[idx];
              \(Self.v2BrowserCssPathScript)
              const finalSelector = __programaCssPath(el);
              if (!finalSelector) return { ok: false, error: 'not_found' };
              return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                return v2BrowserWithAllocatedElementRef(surfaceId: surfaceId, selector: finalSelector) { ref in
                    .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "selector": finalSelector,
                        "element_ref": ref,
                        "ref": ref,
                        "text": v2OrNull(dict["text"])
                    ])
                }
            }
        }
    }

    nonisolated func v2BrowserFindNth(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = v2Int(params, "index") ?? v2Int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              \(Self.v2BrowserCssPathScript)
              const finalSelector = __programaCssPath(el);
              if (!finalSelector) return { ok: false, error: 'not_found' };
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector, "index": index])
                }
                return v2BrowserWithAllocatedElementRef(surfaceId: surfaceId, selector: finalSelector) { ref in
                    .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "selector": finalSelector,
                        "element_ref": ref,
                        "ref": ref,
                        "index": v2OrNull(dict["index"]),
                        "text": v2OrNull(dict["text"])
                    ])
                }
            }
        }
    }

    nonisolated func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return v2BrowserSelectorResolutionError(selectorRaw, surfaceId: surfaceId)
            }
            guard selector.utf8.count <= Self.v2BrowserElementRefSelectorByteLimit else {
                return .err(
                    code: "invalid_params",
                    message: "Frame selector exceeds the supported size limit",
                    data: ["selector_byte_limit": Self.v2BrowserElementRefSelectorByteLimit]
                )
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(
                browserPanel.webView,
                surfaceId: surfaceId,
                script: script,
                useEval: false
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    guard case .applied = v2BrowserApplyFrameSelector(
                        selector,
                        surfaceId: surfaceId,
                        source: .frameSelect
                    ) else {
                        return .err(
                            code: "invalid_params",
                            message: "Frame selector exceeds the supported size limit",
                            data: ["selector_byte_limit": Self.v2BrowserElementRefSelectorByteLimit]
                        )
                    }
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "frame_selector": selector
                    ])
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .err(code: "not_supported", message: "Cross-origin iframe control is not supported", data: ["selector": selector])
                }
                return .err(code: "not_found", message: "Frame not found", data: ["selector": selector])
            }
        }
    }

    nonisolated func v2BrowserFrameMain(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            // Resolve WebKit's live pending completion handler directly. Never evaluate JavaScript
            // here: doing so while a native alert/confirm/prompt sheet is up can deadlock WebKit.
            guard let info = BrowserJSDialogPresenter.resolvePendingDialog(
                for: browserPanel.webView, accept: accept, text: text
            ) else {
                return .err(code: "not_found", message: "No pending dialog", data: ["pending": []])
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "accepted": accept,
                "dialog": [
                    "type": info.kind.rawValue,
                    "message": info.message,
                    "default_text": v2OrNull(info.defaultText)
                ],
                "remaining": 0
            ])
        }
    }

    private nonisolated func v2BrowserDownloadPathLookup(params: [String: Any]) -> V2BrowserDownloadPathLookup {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .failed(.tabManagerUnavailable)
            }
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .failed(.workspaceNotFound)
            }
            let surfaceId = v2UUID(params, "surface_id") ?? workspace.focusedPanelId
            guard let surfaceId else {
                return .failed(.noFocusedSurface)
            }
            guard workspace.browserPanel(for: surfaceId) != nil else {
                return .failed(.surfaceNotBrowser(surfaceId))
            }
            return .resolved(V2BrowserDownloadPathContext(workspaceId: workspace.id, surfaceId: surfaceId))
        }
    }

    private nonisolated static func v2BrowserDownloadPathIsReady(_ path: String) -> Bool {
        var attributes = stat()
        let exists = path.withCString { Darwin.fstatat(AT_FDCWD, $0, &attributes, 0) == 0 }
        return exists && attributes.st_size > 0
    }

    private nonisolated static func v2WaitForBrowserDownloadPath(
        _ path: String,
        timeout: TimeInterval,
        pendingMarkerPath: String?
    ) -> V2BrowserDownloadPathWaitResult {
        if v2BrowserDownloadPathIsReady(path) {
            return .ready
        }

        let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fileDescriptor = open(watchedPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return .failedToWatch
        }

        let queue = DispatchQueue(label: "com.darkroom.programa.browser-download-path-wait", qos: .utility)
        let state = V2BrowserDownloadPathWaitState(fileDescriptor: fileDescriptor)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: queue
        )
        source.setEventHandler {
            if v2BrowserDownloadPathIsReady(path) {
                state.finish(ready: true)
            }
        }
        source.setCancelHandler {
            state.closeFileDescriptorAndAcknowledgeCancellation()
        }
        state.install(source: source)
        source.resume()

        queue.async {
            if v2BrowserDownloadPathIsReady(path) {
                state.finish(ready: true)
                return
            }
#if DEBUG
            if let pendingMarkerPath,
               URL(fileURLWithPath: pendingMarkerPath).standardizedFileURL.path
                   != URL(fileURLWithPath: path).standardizedFileURL.path {
                try? Data("pending".utf8).write(to: URL(fileURLWithPath: pendingMarkerPath), options: .atomic)
            }
#endif
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            state.finish(ready: v2BrowserDownloadPathIsReady(path))
        }

        let ready = state.waitForResult()
        state.waitForCancellationAcknowledgement()
        return ready ? .ready : .timedOut
    }

    nonisolated func v2BrowserDownloadWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 10_000)
        let timeout = Double(timeoutMs) / 1000.0
        guard let path = v2String(params, "path") else {
            return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
                switch v2BrowserWaitForDownloadEvent(surfaceId: surfaceId, timeout: timeout) {
                case .event(let event, let droppedEvents):
                    var payload: [String: Any] = [
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "download": event
                    ]
                    if droppedEvents > 0 {
                        payload["dropped_events"] = droppedEvents
                    }
                    return .ok(payload)
                case .timedOut:
                    return .err(code: "timeout", message: "No download event observed", data: ["timeout_ms": timeoutMs])
                case .cancelled:
                    return .err(
                        code: "not_found",
                        message: "Browser surface closed while waiting for a download",
                        data: ["surface_id": surfaceId.uuidString]
                    )
                case .busy:
                    return .err(
                        code: "busy",
                        message: "Another event-mode download wait is already active",
                        data: ["surface_id": surfaceId.uuidString]
                    )
                }
            }
        }

#if DEBUG
        let pendingMarkerPath = v2String(params, "_test_pending_marker_path")
#else
        let pendingMarkerPath: String? = nil
#endif

        let context: V2BrowserDownloadPathContext
        switch v2BrowserDownloadPathLookup(params: params) {
        case .resolved(let resolvedContext):
            context = resolvedContext
        case .failed(.tabManagerUnavailable):
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .failed(.workspaceNotFound):
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .failed(.noFocusedSurface):
            return .err(code: "not_found", message: "No focused browser surface", data: nil)
        case .failed(.surfaceNotBrowser(let surfaceId)):
            return .err(
                code: "invalid_params",
                message: "Surface is not a browser",
                data: ["surface_id": surfaceId.uuidString]
            )
        }

        switch Self.v2WaitForBrowserDownloadPath(
            path,
            timeout: timeout,
            pendingMarkerPath: pendingMarkerPath
        ) {
        case .ready:
            return .ok([
                "workspace_id": context.workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
                "surface_id": context.surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
                "path": path,
                "downloaded": true
            ])
        case .timedOut:
            return .err(
                code: "timeout",
                message: "Timed out waiting for download file",
                data: ["path": path, "timeout_ms": timeoutMs]
            )
        case .failedToWatch:
            return .err(code: "internal_error", message: "Failed to watch download path", data: ["path": path])
        }
    }

    func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "http_only": cookie.isHTTPOnly,
            "same_site": cookie.sameSitePolicy?.rawValue ?? NSNull(),
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            store.getAllCookies { items in
                finish(items)
            }
        }
    }

    func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.setCookie(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.delete(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cookies": cookies.map(v2BrowserCookieDict)
            ])
        }
    }

    func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = browserPanel.currentURL

            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty {
                    cookieObjects = [single]
                }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "set": setCount
            ])
        }
    }

    func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let clearAll = params["all"] == nil && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cleared": removed
            ])
        }
    }

    nonisolated func v2BrowserStorageType(_ params: [String: Any]) -> String {
        let type = (v2String(params, "storage") ?? v2String(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    nonisolated func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = key.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ])
            }
        }
    }

    nonisolated func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard params.keys.contains("value") else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = v2JSONLiteral(key)
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(params["value"]))
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": key
                ])
            }
        }
    }

    nonisolated func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "cleared": true
                ])
            }
        }
    }

    func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
                [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "title": panel.displayTitle,
                    "url": panel.currentURL?.absoluteString ?? "",
                    "focused": panel.id == ws.focusedPanelId,
                    "pane_id": v2OrNull(ws.paneId(forPanelId: panel.id)?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: ws.paneId(forPanelId: panel.id)?.id)
                ]
            }
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": v2OrNull(ws.focusedPanelId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "tabs": tabs
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let url = v2String(params, "url").flatMap(URL.init(string:))
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let paneUUID = v2UUID(params, "pane_id")
                ?? v2UUID(params, "target_pane_id")
                ?? (v2UUID(params, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found", data: nil)
                return
            }

            guard let panel = ws.newBrowserSurface(inPane: pane, url: url, focus: true) else {
                result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                return
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": pane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: pane.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "url": panel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    func v2BrowserTabSwitch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return v2UUID(params, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            ws.focusPanel(targetId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": targetId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: targetId)
            ])
        }
        return result
    }

    func v2BrowserTabClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                result = .err(code: "not_found", message: "No browser tabs", data: nil)
                return
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = v2UUID(params, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            let ok = ws.closePanel(targetId, force: true)
            result = ok
                ? .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": targetId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                ])
                : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
        }
        return result
    }

    nonisolated func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        let clear = v2Bool(params, "clear") ?? false
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__programaConsoleLog) ? window.__programaConsoleLog.slice() : [];
              if (\(clearLiteral)) {
                window.__programaConsoleLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    nonisolated func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    nonisolated func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        let clear = v2Bool(params, "clear") ?? false
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__programaErrorLog) ? window.__programaErrorLog.slice() : [];
              if (\(clearLiteral)) {
                window.__programaErrorLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    nonisolated func v2BrowserHighlight(params: [String: Any]) -> V2CallResult {
        return v2BrowserSelectorAction(params: params, actionName: "highlight") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const prev = el.style.outline;
              const prevOffset = el.style.outlineOffset;
              el.style.outline = '3px solid #ff9f0a';
              el.style.outlineOffset = '2px';
              setTimeout(() => {
                el.style.outline = prev;
                el.style.outlineOffset = prevOffset;
              }, 1200);
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserStateSave(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let storageScript = """
            (() => {
              const readStorage = (st) => {
                const out = {};
                if (!st) return out;
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return out;
              };
              return {
                local: readStorage(window.localStorage),
                session: readStorage(window.sessionStorage)
              };
            })()
            """

            let storageValue: Any
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (v2BrowserCookieStoreAll(store) ?? []).map(v2BrowserCookieDict)

            let data: Data
            switch V2BrowserStateRestorer.encodeDocument(
                url: browserPanel.currentURL,
                cookies: cookies,
                storage: storageValue,
                frameSelector: v2BrowserFrameSelectorBySurface[surfaceId]
            ) {
            case .success(let encoded):
                data = encoded
            case .failure(let failure):
                return v2BrowserStateRestoreFailureResult(failure, path: path)
            }

            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(code: "internal_error", message: "Failed to write state file", data: ["path": path, "error": error.localizedDescription])
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "cookies": cookies.count
            ])
        }
    }

    func v2BrowserStateLoad(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        let preparedState: V2BrowserStateRestorer.PreparedState
        switch V2BrowserStateRestorer.prepare(fileURL: URL(fileURLWithPath: path)) {
        case .success(let state):
            preparedState = state
        case .failure(let failure):
            return v2BrowserStateRestoreFailureResult(failure, path: path)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let restoreLease = browserPanel.beginBrowserStateRestore() else {
                let dataStoreID = ObjectIdentifier(browserPanel.webView.configuration.websiteDataStore)
                let leaseState = V2BrowserStateRestoreLeaseCoordinator.shared.state(
                    dataStoreID: dataStoreID
                )
                let message = leaseState == .taintedByUndrainedMutationCallbacks
                    ? "Browser data store is waiting for an issued WebKit mutation callback to drain"
                    : "Another browser state restore is already active on this data store"
                return .err(
                    code: "busy",
                    message: message,
                    data: [
                        "surface_id": surfaceId.uuidString,
                        "path": path,
                        "busy_reason": leaseState.rawValue,
                    ]
                )
            }
            defer { browserPanel.endBrowserStateRestore(restoreLease) }

            let restoreWebView = browserPanel.webView
            let restoreWebViewInstanceID = browserPanel.webViewInstanceID
            let leaseCoordinator = V2BrowserStateRestoreLeaseCoordinator.shared
            let operations = V2BrowserStateRestoreOperations(
                installCookies: { cookies, _ in
                    guard browserPanel.webView === restoreWebView,
                          browserPanel.webViewInstanceID == restoreWebViewInstanceID else {
                        return .unavailable(message: "Browser surface changed before cookies were installed")
                    }
                    guard !cookies.isEmpty else { return .succeeded }

                    let cookieStore = restoreWebView.configuration.websiteDataStore.httpCookieStore
                    guard leaseCoordinator.beginPendingMutation(restoreLease) else {
                        return .unavailable(message: "Browser state restore was invalidated before cookies were installed")
                    }
                    let completed: Void? = self.v2AwaitCallback(timeout: 10.0) { finish in
                        let group = DispatchGroup()
                        for cookie in cookies {
                            group.enter()
                            cookieStore.setCookie(cookie) {
                                group.leave()
                            }
                        }
                        group.notify(queue: .main) {
                            leaseCoordinator.endPendingMutation(restoreLease)
                            finish(())
                        }
                    }
                    guard completed != nil else { return .timedOut }
                    guard browserPanel.webView === restoreWebView,
                          browserPanel.webViewInstanceID == restoreWebViewInstanceID else {
                        return .unavailable(message: "Browser surface changed while cookies were being installed")
                    }
                    return .succeeded
                },
                navigateAndWait: { targetURL in
                    let result: V2BrowserStateNavigationOutcome? = self.v2AwaitCallback(timeout: 20.0) { finish in
                        let startOutcome = browserPanel.startBrowserStateRestoreNavigation(to: targetURL) { outcome in
                            switch outcome {
                            case .finished(let committed, let finished):
                                finish(
                                    .finished(
                                        committed: V2BrowserStateNavigationMilestone(
                                            navigationID: committed.navigationID,
                                            url: committed.url,
                                            executionURL: committed.executionURL
                                        ),
                                        finished: V2BrowserStateNavigationMilestone(
                                            navigationID: finished.navigationID,
                                            url: finished.url,
                                            executionURL: finished.executionURL
                                        )
                                    )
                                )
                            case .cancelled:
                                finish(.cancelled)
                            case .permissionDenied:
                                finish(.permissionDenied)
                            case .unavailable:
                                finish(.unavailable)
                            case .failed(let message):
                                finish(.failed(message: message))
                            }
                        }
                        switch startOutcome {
                        case .started:
                            break
                        case .permissionDenied:
                            finish(.permissionDenied)
                        case .unavailable:
                            finish(.unavailable)
                        case .busy:
                            finish(.busy)
                        }
                    }
                    guard let result else {
                        return .timedOut
                    }
                    return result
                },
                applyStorage: { storage in
                    guard browserPanel.webView === restoreWebView,
                          browserPanel.webViewInstanceID == restoreWebViewInstanceID,
                          let actualURL = restoreWebView.url else {
                        return .unavailable(message: "Browser surface changed before storage was applied")
                    }
                    guard V2BrowserStateRestorer.originString(for: actualURL) == storage.executionOrigin else {
                        return .originMismatch(message: "Browser origin changed before storage was applied")
                    }

                    let storageLiteral = self.v2JSONLiteral([
                        "local": storage.local,
                        "session": storage.session,
                    ])
                    let originLiteral = self.v2JSONLiteral(storage.executionOrigin)
                    let script = """
                    return (() => {
                      const expectedOrigin = \(originLiteral);
                      const payload = \(storageLiteral);
                      try {
                        const actualOrigin = String(location.origin || '');
                        if (actualOrigin !== expectedOrigin) {
                          return { ok: false, kind: 'origin_mismatch', actual_origin: actualOrigin };
                        }
                        const apply = (target, entries) => {
                          target.clear();
                          for (const [key, value] of Object.entries(entries)) {
                            target.setItem(key, value);
                          }
                        };
                        apply(window.localStorage, payload.local);
                        apply(window.sessionStorage, payload.session);
                        return { ok: true };
                      } catch (error) {
                        return {
                          ok: false,
                          kind: 'storage_error',
                          message: String(error && error.message ? error.message : error)
                        };
                      }
                    })();
                    """
                    guard leaseCoordinator.beginPendingMutation(restoreLease) else {
                        return .unavailable(message: "Browser state restore was invalidated before storage was applied")
                    }
                    switch self.v2RunJavaScript(
                        restoreWebView,
                        script: script,
                        timeout: 10.0,
                        preferAsync: true,
                        contentWorld: .defaultClient,
                        webKitCompletionDidDrain: {
                            leaseCoordinator.endPendingMutation(restoreLease)
                        }
                    ) {
                    case .failure(let message):
                        if message == "Timed out waiting for JavaScript result" {
                            return .timedOut
                        }
                        return .failed(message: message)
                    case .success(let value):
                        guard let response = value as? [String: Any],
                              let ok = response["ok"] as? Bool else {
                            return .failed(message: "Invalid browser storage result")
                        }
                        if ok { return .succeeded }
                        if response["kind"] as? String == "origin_mismatch" {
                            return .originMismatch(message: "Browser origin changed while storage was being applied")
                        }
                        return .failed(
                            message: (response["message"] as? String) ?? "Browser storage mutation failed"
                        )
                    }
                },
                applyFrameSelector: { frameSelector in
                    switch self.v2BrowserApplyFrameSelector(
                        frameSelector,
                        surfaceId: surfaceId,
                        source: .stateLoad
                    ) {
                    case .applied:
                        return .succeeded
                    case .rejected(let limit):
                        return .failed(message: "Frame selector exceeds \(limit) bytes")
                    }
                },
                leaseIsValid: {
                    browserPanel.isBrowserStateRestoreLeaseValid(restoreLease)
                        && browserPanel.webView === restoreWebView
                        && browserPanel.webViewInstanceID == restoreWebViewInstanceID
                },
                cancelNavigation: {
                    browserPanel.cancelBrowserStateRestoreNavigationWait()
                }
            )

            switch V2BrowserStateRestorer.execute(preparedState, using: operations) {
            case .failure(let failure):
                return v2BrowserStateRestoreFailureResult(failure, path: path)
            case .success:
                break
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "loaded": true,
                "url": preparedState.targetURL.absoluteString,
                "cookies": preparedState.cookies.count,
            ])
        }
    }

    private func v2BrowserStateRestoreFailureResult(
        _ failure: V2BrowserStateRestoreFailure,
        path: String
    ) -> V2CallResult {
        let code: String
        switch failure.code {
        case .documentReadFailed:
            code = "not_found"
        case .documentNotRegular, .documentTooLarge, .malformedDocument, .unsupportedSchemaVersion,
             .invalidURL, .invalidCookie, .duplicateCookie,
             .cookieLimitExceeded, .storageEntryLimitExceeded, .storageKeyTooLarge,
             .storageValueTooLarge, .frameSelectorTooLarge:
            code = "invalid_params"
        case .navigationPermissionDenied:
            code = "permission_denied"
        case .navigationUnavailable, .surfaceUnavailable, .cookieInstallFailed, .restoreInvalidated:
            code = "unavailable"
        case .navigationBusy:
            code = "busy"
        case .navigationTimedOut, .cookieInstallTimedOut, .storageApplyTimedOut,
             .frameSelectorApplyTimedOut:
            code = "timeout"
        case .navigationCancelled:
            code = "cancelled"
        case .navigationFailed, .navigationMismatch:
            code = "navigation_failed"
        case .originMismatch:
            code = "origin_mismatch"
        case .storageApplyFailed:
            code = "storage_apply_failed"
        case .frameSelectorApplyFailed:
            code = "internal_error"
        }

        var data: [String: Any] = ["path": path]
        if failure.cookiesMayHaveBeenMutated {
            data["partial_cookie_mutation"] = true
            data["cookies_attempted"] = failure.cookieCount
        }
        if failure.storageMayHaveBeenMutated {
            data["partial_storage_mutation"] = true
        }
        return .err(code: code, message: failure.message, data: data)
    }

    nonisolated func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
            scripts.append(script)
            v2BrowserInitScriptsBySurface[surfaceId] = scripts

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "scripts": scripts.count
            ])
        }
    }

    nonisolated func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    nonisolated func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
            styles.append(css)
            v2BrowserInitStylesBySurface[surfaceId] = styles

            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: source, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "styles": styles.count
            ])
        }
    }

    nonisolated func v2BrowserViewportSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.viewport.set", details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP")
    }

    nonisolated func v2BrowserGeolocationSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.geolocation.set", details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP")
    }

    nonisolated func v2BrowserOfflineSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.offline.set", details: "WKWebView does not expose reliable per-tab offline emulation")
    }

    nonisolated func v2BrowserTraceStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.start", details: "Playwright trace artifacts are not available on WKWebView")
    }

    nonisolated func v2BrowserTraceStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.stop", details: "Playwright trace artifacts are not available on WKWebView")
    }

    nonisolated func v2BrowserNetworkRoute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2MainSync {
                v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "route", "params": params])
            }
        }
        return v2BrowserNotSupported("browser.network.route", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    nonisolated func v2BrowserNetworkUnroute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2MainSync {
                v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "unroute", "params": params])
            }
        }
        return v2BrowserNotSupported("browser.network.unroute", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    nonisolated func v2BrowserNetworkRequests(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            let items: [[String: Any]] = v2MainSync {
                v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            }
            return .err(code: "not_supported", message: "browser.network.requests is not supported on WKWebView", data: [
                "details": "Request interception logs are unavailable without CDP network hooks",
                "recorded_requests": items
            ])
        }
        return v2BrowserNotSupported("browser.network.requests", details: "Request interception logs are unavailable without CDP network hooks")
    }

    nonisolated func v2BrowserScreencastStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.start", details: "WKWebView does not expose CDP screencast streaming")
    }

    nonisolated func v2BrowserScreencastStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.stop", details: "WKWebView does not expose CDP screencast streaming")
    }

    nonisolated func v2BrowserInputMouse(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_mouse", details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll")
    }

    nonisolated func v2BrowserInputKeyboard(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_keyboard", details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup")
    }

    nonisolated func v2BrowserInputTouch(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_touch", details: "Raw CDP touch injection is unavailable on WKWebView")
    }

}
