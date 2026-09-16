import AppKit
import SwiftUI
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// `~/.claude/tmp/rate-limits.json` is written by an external tool (cc-settings) that we do
/// not control, so the parser has to be total: malformed input yields `nil`, never a crash
/// and never a partially-filled snapshot.
///
/// The payload also mixes time units in a single object -- `resets_at` is epoch SECONDS
/// (as a string) while `updated_at` is epoch MILLISECONDS (as a number). Getting that
/// backwards silently renders reset countdowns that are wrong by a factor of 1000, which is
/// exactly the kind of bug that looks fine in review, so it is pinned here.
final class ClaudeQuotaSnapshotParserTests: XCTestCase {
    /// Verbatim shape of a real file observed on disk.
    private func payload(
        fiveHourPercent: String = "17",
        fiveHourResets: String = "\"1785171600\"",
        sevenDayPercent: String = "3",
        sevenDayResets: String = "\"1785664800\"",
        updatedAt: String = "1785168986314"
    ) -> Data {
        Data("""
        {"five_hour":{"used_percentage":\(fiveHourPercent),"resets_at":\(fiveHourResets)},
         "seven_day":{"used_percentage":\(sevenDayPercent),"resets_at":\(sevenDayResets)},
         "updated_at":\(updatedAt)}
        """.utf8)
    }

    func testParsesRealPayload() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.fiveHour.usedPercent, 17)
        XCTAssertEqual(snapshot.sevenDay.usedPercent, 3)
    }

    /// `resets_at` is a string holding epoch SECONDS.
    func testResetsAtIsParsedAsEpochSeconds() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.fiveHour.resetsAt.timeIntervalSince1970, 1_785_171_600, accuracy: 1)
        XCTAssertEqual(snapshot.sevenDay.resetsAt.timeIntervalSince1970, 1_785_664_800, accuracy: 1)
    }

    /// `updated_at` is a number holding epoch MILLISECONDS -- a different unit from
    /// `resets_at` in the same payload.
    func testUpdatedAtIsParsedAsEpochMilliseconds() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, 1_785_168_986.314, accuracy: 1)
    }

    /// The three timestamps come from one file; if units were confused, `updated_at` would
    /// land ~55 years past the reset times instead of just before them.
    func testUpdatedAtPrecedesResetTimes() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertLessThan(snapshot.updatedAt, snapshot.fiveHour.resetsAt)
        XCTAssertLessThan(snapshot.fiveHour.resetsAt, snapshot.sevenDay.resetsAt)
    }

    func testReturnsNilForMalformedJSON() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: Data("{not json".utf8)))
    }

    func testReturnsNilForEmptyData() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: Data()))
    }

    func testReturnsNilWhenAWindowIsMissing() {
        let data = Data("""
        {"five_hour":{"used_percentage":17,"resets_at":"1785171600"},
         "updated_at":1785168986314}
        """.utf8)

        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: data))
    }

    func testReturnsNilWhenPercentageHasWrongType() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourPercent: "\"seventeen\"")))
    }

    func testReturnsNilWhenResetTimestampIsNotNumeric() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourResets: "\"soon\"")))
    }

    func testRejectsResetDatesThatCannotSafelyProduceCountdowns() {
        let invalid = ["nan", "inf", "-inf", "1e309", "1e100", "-1",
                       String(Date.distantFuture.timeIntervalSince1970 + 1)]
        for timestamp in invalid {
            XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourResets: "\"\(timestamp)\"")), timestamp)
            XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(sevenDayResets: "\"\(timestamp)\"")), timestamp)
        }
    }

    func testAcceptsSupportedResetDateBoundaries() throws {
        for seconds in [0.0, Date.distantFuture.timeIntervalSince1970] {
            let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload(
                fiveHourResets: "\"\(seconds)\"", sevenDayResets: "\"\(seconds)\""
            )))
            XCTAssertEqual(snapshot.fiveHour.resetsAt.timeIntervalSince1970, seconds)
            XCTAssertEqual(snapshot.sevenDay.resetsAt.timeIntervalSince1970, seconds)
        }
    }

    func testClampsPercentagesFromTheExternalClaudeCache() throws {
        let snapshot = try XCTUnwrap(
            ClaudeQuotaSnapshotParser.parse(
                data: payload(fiveHourPercent: "-12", sevenDayPercent: "145")
            )
        )

        XCTAssertEqual(snapshot.fiveHour.usedPercent, 0)
        XCTAssertEqual(snapshot.sevenDay.usedPercent, 100)
    }

    func testMapsTheExistingClaudeCacheIntoTheNormalizedProviderModel() {
        let result = ClaudeUsageSnapshotParser.parse(data: payload())

        guard case let .available(snapshot) = result else {
            return XCTFail("A valid Claude cache must be available through the shared provider model, got \(result)")
        }
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.windows.map(\.id), ["claude.five_hour", "claude.seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["Current session", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [17, 3])
        XCTAssertEqual(
            snapshot.windows.map { $0.resetsAt.timeIntervalSince1970 },
            [1_785_171_600, 1_785_664_800]
        )
    }

    func testNormalizedClaudeParserSurfacesMalformedCacheAsAProviderFailure() {
        let result = ClaudeUsageSnapshotParser.parse(data: Data("{not json".utf8))

        guard case let .failed(.claude, message) = result else {
            return XCTFail("A malformed Claude cache must surface an explicit provider error, got \(result)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testClaudeAuthStatusOverridesAValidCacheWhenTheOfficialCLIIsSignedOut() async throws {
        let now = Date(timeIntervalSince1970: 1_785_168_986)
        let fixture = try ClaudeUsageFixture.make(
            authBody: #"print -r -- '{"loggedIn":false}'"#,
            cacheData: payload(updatedAt: String(Int(now.timeIntervalSince1970 * 1_000)))
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let result = await ClaudeProviderUsageFetcher.fetchForTesting(
            executableURL: fixture.executableURL,
            cacheURL: fixture.cacheURL,
            timeout: 0.5,
            now: now
        )

        guard case .unavailable(.claude) = result else {
            return XCTFail("A signed-out authoritative Claude CLI must hide a leftover usage cache, got \(result)")
        }
        XCTAssertEqual(
            try fixture.invocations(),
            ["auth status --json"],
            "Login state must come from the official Claude CLI contract"
        )
    }

    func testSignedOutClaudeCLIExitStatusStillHidesTheProviderInsteadOfFailing() async throws {
        let now = Date(timeIntervalSince1970: 1_785_168_986)
        let fixture = try ClaudeUsageFixture.make(
            authBody: #"print -r -- '{"loggedIn":false}'; exit 1"#,
            cacheData: payload(updatedAt: String(Int(now.timeIntervalSince1970 * 1_000)))
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let result = await ClaudeProviderUsageFetcher.fetchForTesting(
            executableURL: fixture.executableURL,
            cacheURL: fixture.cacheURL,
            timeout: 0.5,
            now: now
        )

        guard case .unavailable(.claude) = result else {
            return XCTFail("The official CLI exits 1 when signed out; a parseable answer must hide the provider, got \(result)")
        }
    }

    func testLoggedInClaudeWithAFreshRegularBoundedCacheIsAvailable() async throws {
        let now = Date(timeIntervalSince1970: 1_785_168_986)
        let fixture = try ClaudeUsageFixture.make(
            authBody: #"print -r -- '{"loggedIn":true}'"#,
            cacheData: payload(updatedAt: String(Int(now.timeIntervalSince1970 * 1_000)))
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let result = await ClaudeProviderUsageFetcher.fetchForTesting(
            executableURL: fixture.executableURL,
            cacheURL: fixture.cacheURL,
            timeout: 0.5,
            now: now
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("A logged-in Claude session with a fresh safe cache must render usage, got \(result)")
        }
        XCTAssertEqual(snapshot.windows.map(\.label), ["Current session", "Weekly"])
    }

    func testUnsafeOrStaleClaudeCachesAreRejectedWithoutReadingThroughThem() async throws {
        let now = Date(timeIntervalSince1970: 1_785_168_986)
        let stale = payload(updatedAt: String(Int((now.timeIntervalSince1970 - 7_200) * 1_000)))
        let fresh = payload(updatedAt: String(Int(now.timeIntervalSince1970 * 1_000)))
        var oversized = fresh
        oversized.append(Data(repeating: 0x20, count: 1_048_577))

        for cacheKind in ClaudeUsageFixture.UnsafeCacheKind.allCases {
            let fixture = try ClaudeUsageFixture.make(
                authBody: #"print -r -- '{"loggedIn":true}'"#,
                cacheData: cacheKind == .stale ? stale : (cacheKind == .oversized ? oversized : fresh),
                unsafeCacheKind: cacheKind
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directoryURL) }

            let result = await ClaudeProviderUsageFetcher.fetchForTesting(
                executableURL: fixture.executableURL,
                cacheURL: fixture.cacheURL,
                timeout: 0.5,
                now: now
            )

            guard case .unavailable(.claude) = result else {
                return XCTFail("A \(cacheKind) cache must be rejected as unavailable without unsafe reads, got \(result)")
            }
        }
    }

    func testClaudeAuthTimeoutAndErrorsAreBoundedAndNeverExposeCLIOutput() async throws {
        let now = Date(timeIntervalSince1970: 1_785_168_986)
        let cache = payload(updatedAt: String(Int(now.timeIntervalSince1970 * 1_000)))
        let cases = [
            "sleep 1",
            "print -ru2 -- 'private-auth-output'; exit 7",
        ]

        for authBody in cases {
            let fixture = try ClaudeUsageFixture.make(authBody: authBody, cacheData: cache)
            addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directoryURL) }
            let clock = ContinuousClock()
            let startedAt = clock.now

            let result = await ClaudeProviderUsageFetcher.fetchForTesting(
                executableURL: fixture.executableURL,
                cacheURL: fixture.cacheURL,
                timeout: 0.15,
                now: now
            )

            guard case let .failed(.claude, message) = result else {
                return XCTFail("An indeterminate authoritative login check must be a provider failure, got \(result)")
            }
            XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(600))
            XCTAssertFalse(message.contains("private-auth-output"))
        }
    }
}

private struct ClaudeUsageFixture {
    enum UnsafeCacheKind: CaseIterable, CustomStringConvertible {
        case stale
        case symlink
        case nonregular
        case oversized

        var description: String {
            switch self {
            case .stale: return "stale"
            case .symlink: return "symlinked"
            case .nonregular: return "non-regular"
            case .oversized: return "oversized"
            }
        }
    }

    let directoryURL: URL
    let executableURL: URL
    let cacheURL: URL
    let invocationURL: URL

    static func make(
        authBody: String,
        cacheData: Data,
        unsafeCacheKind: UnsafeCacheKind? = nil
    ) throws -> Self {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-claude-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let executableURL = directoryURL.appendingPathComponent("claude")
        let invocationURL = directoryURL.appendingPathComponent("invocations.log")
        let cacheURL = directoryURL.appendingPathComponent("rate-limits.json")
        let script = """
        #!/bin/zsh
        print -r -- "$*" >> \(shellQuote(invocationURL.path))
        \(authBody)
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        switch unsafeCacheKind {
        case .symlink:
            let targetURL = directoryURL.appendingPathComponent("actual-rate-limits.json")
            try cacheData.write(to: targetURL)
            try FileManager.default.createSymbolicLink(at: cacheURL, withDestinationURL: targetURL)
        case .nonregular:
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        default:
            try cacheData.write(to: cacheURL)
        }
        return Self(
            directoryURL: directoryURL,
            executableURL: executableURL,
            cacheURL: cacheURL,
            invocationURL: invocationURL
        )
    }

    func invocations() throws -> [String] {
        String(decoding: try Data(contentsOf: invocationURL), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Codex account state is intentionally read through the documented app-server RPCs. These
/// fixtures are complete JSON-RPC responses so the parser cannot accidentally become coupled to
/// auth files or to the private ChatGPT usage endpoint.
final class CodexUsageSnapshotParserTests: XCTestCase {
    private func accountResponse(_ account: String) -> Data {
        Data("""
        {"id":1,"result":{"account":\(account),"requiresOpenaiAuth":true}}
        """.utf8)
    }

    private var chatGPTAccountResponse: Data {
        accountResponse(#"{"type":"chatgpt","email":"person@example.com","planType":"pro"}"#)
    }

    private func rateLimitsResponse(_ result: String) -> Data {
        Data("""
        {"id":2,"result":\(result)}
        """.utf8)
    }

    func testNullAccountIsExplicitlyUnavailable() {
        let result = CodexUsageSnapshotParser.parse(
            accountData: accountResponse("null"),
            rateLimitsData: rateLimitsResponse(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#)
        )

        guard case .unavailable(.codex) = result else {
            return XCTFail("A signed-out app-server account must be reported as unavailable, got \(result)")
        }
    }

    func testParsesPrimaryAndSecondaryWindowsAndClampsBackendPercentages() throws {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":-4,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":124,"windowDurationMins":10080,"resetsAt":1785664800},"rateLimitReachedType":null},"rateLimitsByLimitId":{}}"#
            )
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("Expected an available Codex quota snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.windows.map(\.id), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["Current window", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 100])
        XCTAssertEqual(
            snapshot.windows.map { $0.resetsAt.timeIntervalSince1970 },
            [1_785_171_600, 1_785_664_800]
        )
    }

    func testUsesOnlyUnifiedChatGPTUsageAndIgnoresModelSpecificBuckets() throws {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785664800}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785664800}},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":35,"windowDurationMins":300,"resetsAt":1785175200},"secondary":null}}}"#
            )
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("Expected unified ChatGPT usage to remain available, got \(result)")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(snapshot.windows.map(\.label), ["Current window", "Weekly"])
        XCTAssertEqual(
            snapshot.windows.map(\.usedPercent),
            [10, 20],
            "The meter must match ChatGPT's unified account usage instead of adding model-specific rows"
        )
    }

    func testFallsBackToUnifiedCodexBucketWhenTopLevelAggregateIsNullOrAbsent() throws {
        let unified = #"{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1785664800}}"#
        let named = #"{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":77,"windowDurationMins":300,"resetsAt":1785175200},"secondary":null}"#
        let results = [
            #"{"rateLimits":null,"rateLimitsByLimitId":{"codex":\#(unified),"codex_bengalfox":\#(named)}}"#,
            #"{"rateLimitsByLimitId":{"codex":\#(unified),"codex_bengalfox":\#(named)}}"#,
        ]

        for rateResult in results {
            let result = CodexUsageSnapshotParser.parse(
                accountData: chatGPTAccountResponse,
                rateLimitsData: rateLimitsResponse(rateResult)
            )

            guard case let .available(snapshot) = result else {
                return XCTFail("The unified codex bucket must remain authoritative when rateLimits is null or absent, got \(result)")
            }
            XCTAssertEqual(snapshot.windows.map(\.id), ["codex.primary", "codex.secondary"])
            XCTAssertEqual(snapshot.windows.map(\.label), ["Current window", "Weekly"])
            XCTAssertEqual(
                snapshot.windows.map(\.usedPercent),
                [11, 22],
                "Named model buckets must not become extra usage rows during aggregate fallback"
            )
        }
    }

    func testRejectsResetEpochThatCannotBeRepresentedSafelyForPresentation() {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1e100},"secondary":null},"rateLimitsByLimitId":{}}"#
            )
        )

        guard case let .failed(.codex, message) = result else {
            return XCTFail("An unrepresentable reset date must fail before it reaches UI date conversion, got \(result)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testParsesPlanAndNonEmptyCreditMetadataWithoutCreatingAnotherUsageRow() throws {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785664800},"credits":{"hasCredits":true,"balance":"12.50","unlimited":false}},"rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":3,"credits":[]}}"#
            )
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("Expected account usage with credits to remain available, got \(result)")
        }
        XCTAssertEqual(snapshot.windows.count, 2, "Credits are account context, not another rate-limit row")
        XCTAssertEqual(snapshot.summary?.plan, "pro")
        XCTAssertEqual(snapshot.summary?.credits?.balance, "12.50")
        XCTAssertEqual(snapshot.summary?.credits?.isUnlimited, false)
        XCTAssertEqual(snapshot.summary?.resetCreditsAvailable, 3)
    }

    func testAuthenticatedAccountWithNoQuotaWindowsIsExplicitlyUnavailable() {
        let result = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","primary":null,"secondary":null},"rateLimitsByLimitId":{}}"#
            )
        )

        guard case .unavailable(.codex) = result else {
            return XCTFail("An authenticated account without an authoritative quota must not render invented usage, got \(result)")
        }
    }

    func testMalformedOrPartialRPCResponsesBecomeFailuresInsteadOfCrashes() {
        let malformedAccount = CodexUsageSnapshotParser.parse(
            accountData: Data("{not json".utf8),
            rateLimitsData: rateLimitsResponse(#"{"rateLimits":null}"#)
        )
        let missingReset = CodexUsageSnapshotParser.parse(
            accountData: chatGPTAccountResponse,
            rateLimitsData: rateLimitsResponse(
                #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":null}}"#
            )
        )

        for result in [malformedAccount, missingReset] {
            guard case let .failed(.codex, message) = result else {
                return XCTFail("Malformed or partial authoritative responses must surface a Codex error, got \(result)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testAppServerWaitsForInitializeBeforeRequestingUsageAndKeepsInputOpenForResponses() async throws {
        let fake = try FakeCodexAppServer.make(
            initializationResponse: #"{"jsonrpc":"2.0","id":0,"result":{}}"#
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directoryURL) }

        let result = await CodexProviderUsageFetcher.fetchForTesting(
            executableURL: fake.executableURL,
            timeout: 1
        )

        guard case let .available(snapshot) = result else {
            return XCTFail("A valid sequential app-server exchange must expose Codex usage, got \(result)")
        }
        XCTAssertEqual(snapshot.windows.map(\.label), ["Current window", "Weekly"])
        let events = try fake.events()
        XCTAssertEqual(events.first, "initialize")
        XCTAssertFalse(events.contains("usage-before-initialize-response"))
        XCTAssertFalse(events.contains("stdin-closed-before-usage-responses"))
    }

    func testMalformedOrWrongInitializeResponseFailsWithinTheConfiguredDeadline() async throws {
        for response in ["not-json", #"{"jsonrpc":"2.0","id":99,"result":{}}"#] {
            let fake = try FakeCodexAppServer.make(initializationResponse: response)
            addTeardownBlock { try? FileManager.default.removeItem(at: fake.directoryURL) }
            let clock = ContinuousClock()
            let startedAt = clock.now

            let result = await CodexProviderUsageFetcher.fetchForTesting(
                executableURL: fake.executableURL,
                timeout: 0.5
            )

            guard case .failed(.codex, _) = result else {
                return XCTFail("Usage RPCs must not proceed after an invalid initialize response, got \(result)")
            }
            XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        }
    }

    func testInitializeRPCErrorTerminatesPromptlyWithoutWaitingForTheFullDeadline() async throws {
        let fake = try FakeCodexAppServer.makeInitializationErrorThenDelay(delay: 0.7)
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directoryURL) }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = await CodexProviderUsageFetcher.fetchForTesting(
            executableURL: fake.executableURL,
            timeout: 1
        )

        guard case .failed(.codex, _) = result else {
            return XCTFail("An explicit initialization error must fail the provider, got \(result)")
        }
        XCTAssertLessThan(
            startedAt.duration(to: clock.now),
            .milliseconds(400),
            "An authoritative id=0 error should terminate immediately instead of consuming the session timeout"
        )
    }

    func testLongLivedServerWithAnIdleStderrPipeDoesNotStallTheResponseReader() async throws {
        let fake = try FakeCodexAppServer.make(
            initializationResponse: #"{"jsonrpc":"2.0","id":0,"result":{}}"#,
            responseDelay: 0.01,
            lingerAfterResponses: 3
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directoryURL) }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = await CodexProviderUsageFetcher.fetchForTesting(
            executableURL: fake.executableURL,
            timeout: 1
        )

        guard case let .available(snapshot) = result, snapshot.provider == .codex else {
            return XCTFail("The real app server stays alive after answering; its responses must be read anyway, got \(result)")
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(800))
    }

    func testConcurrentClaudeAndCodexProbesDoNotStarveEachOther() async throws {
        let now = Date(timeIntervalSince1970: 1_785_168_986)
        let claude = try ClaudeUsageFixture.make(
            authBody: #"print -r -- '{"loggedIn":true}'"#,
            cacheData: Data("""
            {"five_hour":{"used_percentage":17,"resets_at":"1785171600"},
             "seven_day":{"used_percentage":3,"resets_at":"1785664800"},
             "updated_at":\(Int(now.timeIntervalSince1970 * 1_000))}
            """.utf8)
        )
        let codex = try FakeCodexAppServer.make(
            initializationResponse: #"{"jsonrpc":"2.0","id":0,"result":{}}"#,
            responseDelay: 0.01,
            lingerAfterResponses: 3
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: claude.directoryURL)
            try? FileManager.default.removeItem(at: codex.directoryURL)
        }

        let results = await withTaskGroup(of: ProviderUsageResult.self, returning: [ProviderUsageResult].self) { group in
            group.addTask {
                await ClaudeProviderUsageFetcher.fetchForTesting(
                    executableURL: claude.executableURL,
                    cacheURL: claude.cacheURL,
                    timeout: 1,
                    now: now
                )
            }
            group.addTask {
                await CodexProviderUsageFetcher.fetchForTesting(executableURL: codex.executableURL, timeout: 1)
            }
            var collected: [ProviderUsageResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for result in results {
            guard case .available = result else {
                return XCTFail("Both providers are probed together when the popover opens; neither may time out, got \(results)")
            }
        }
    }

    func testFastExitingServerStillReturnsTheFinalAccountAndRateLimitResponses() async throws {
        let fake = try FakeCodexAppServer.make(
            initializationResponse: #"{"jsonrpc":"2.0","id":0,"result":{}}"#,
            responseDelay: 0.01
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directoryURL) }

        let result = await CodexProviderUsageFetcher.fetchForTesting(
            executableURL: fake.executableURL,
            timeout: 1
        )

        guard case let .available(snapshot) = result, snapshot.provider == .codex else {
            return XCTFail("Responses written immediately before process exit must not be lost, got \(result)")
        }
    }

    func testDescendantsHoldingPipesCannotExtendTheInjectedDeadlineOrCancellation() async throws {
        for mode in [FakeCodexAppServer.RetentionMode.deadline, .cancellation] {
            let fake = try FakeCodexAppServer.makePipeRetainingDescendant(retention: 0.8)
            addTeardownBlock { try? FileManager.default.removeItem(at: fake.directoryURL) }
            let clock = ContinuousClock()
            let startedAt = clock.now
            let task = Task {
                await CodexProviderUsageFetcher.fetchForTesting(
                    executableURL: fake.executableURL,
                    timeout: mode == .deadline ? 0.15 : 2
                )
            }
            if mode == .cancellation {
                try await Task.sleep(for: .milliseconds(80))
                task.cancel()
            }

            let result = await task.value

            guard case .failed(.codex, _) = result else {
                return XCTFail("A timed-out or cancelled app-server tree must fail safely, got \(result)")
            }
            XCTAssertLessThan(
                startedAt.duration(to: clock.now),
                .milliseconds(550),
                "Descendants retaining stdout/stderr must not outlive the fetch deadline or cancellation"
            )
        }
    }
}

private struct FakeCodexAppServer {
    enum RetentionMode: Equatable {
        case deadline
        case cancellation
    }

    let directoryURL: URL
    let executableURL: URL
    let eventsURL: URL

    static func make(
        initializationResponse: String,
        responseDelay: TimeInterval = 0.12,
        lingerAfterResponses: TimeInterval = 0
    ) throws -> Self {
        try makeScript { eventsPath in
            """
            IFS= read -r initialize
            print -r -- initialize >> \(eventsPath)
            typeset premature=""
            if IFS= read -r -t 0.10 premature; then
              print -r -- usage-before-initialize-response >> \(eventsPath)
            fi
            print -r -- \(shellQuote(initializationResponse))
            if [[ -z $premature ]]; then
              IFS= read -r initialized
            fi
            IFS= read -r account
            IFS= read -r rate_limits
            typeset -F started=$EPOCHREALTIME
            IFS= read -r -t \(responseDelay) extra
            typeset -F elapsed=$(( EPOCHREALTIME - started ))
            if (( elapsed < \(max(responseDelay / 3, 0.01)) )); then
              print -r -- stdin-closed-before-usage-responses >> \(eventsPath)
            fi
            print -r -- '{"jsonrpc":"2.0","id":1,"result":{"account":{"type":"chatgpt"}}}'
            print -r -- '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":1785171600},"secondary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1785664800}},"rateLimitsByLimitId":{}}}'
            sleep \(lingerAfterResponses)
            """
        }
    }

    static func makeInitializationErrorThenDelay(delay: TimeInterval) throws -> Self {
        try makeScript { _ in
            """
            IFS= read -r initialize
            print -r -- '{"jsonrpc":"2.0","id":0,"error":{"code":-32000,"message":"denied"}}'
            sleep \(delay)
            """
        }
    }

    static func makePipeRetainingDescendant(retention: TimeInterval) throws -> Self {
        try makeScript { _ in
            """
            trap '' TERM
            ( sleep \(retention) ) &
            sleep \(retention)
            """
        }
    }

    func events() throws -> [String] {
        String(decoding: try Data(contentsOf: eventsURL), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    private static func makeScript(body: (String) -> String) throws -> Self {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-codex-app-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let executableURL = directoryURL.appendingPathComponent("codex")
        let eventsURL = directoryURL.appendingPathComponent("events.log")
        let script = """
        #!/bin/zsh
        set -u
        zmodload zsh/datetime
        \(body(shellQuote(eventsURL.path)))
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return Self(directoryURL: directoryURL, executableURL: executableURL, eventsURL: eventsURL)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private actor CountingProviderUsageFetcher: ProviderUsageFetching {
    nonisolated let provider: ProviderUsageProvider
    private let result: ProviderUsageResult
    private(set) var callCount = 0

    init(provider: ProviderUsageProvider, result: ProviderUsageResult) {
        self.provider = provider
        self.result = result
    }

    func fetch() async -> ProviderUsageResult {
        callCount += 1
        return result
    }
}

private actor ControllableProviderUsageFetcher: ProviderUsageFetching {
    nonisolated let provider: ProviderUsageProvider
    private var nextCallID = 0
    private var continuations: [Int: CheckedContinuation<ProviderUsageResult, Never>] = [:]
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(provider: ProviderUsageProvider) {
        self.provider = provider
    }

    func fetch() async -> ProviderUsageResult {
        return await withCheckedContinuation { continuation in
            let callID = nextCallID
            nextCallID += 1
            continuations[callID] = continuation
            resumeSatisfiedCallWaiters()
        }
    }

    func waitUntilCallCount(_ count: Int) async {
        guard nextCallID < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func complete(callID: Int, with result: ProviderUsageResult) {
        continuations.removeValue(forKey: callID)?.resume(returning: result)
    }

    private func resumeSatisfiedCallWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if nextCallID >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        callWaiters = pending
    }
}

private actor CancellationObservingProviderUsageFetcher: ProviderUsageFetching {
    nonisolated let provider: ProviderUsageProvider
    private var hasStarted = false
    private var observedCancellation = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: ProviderUsageProvider) {
        self.provider = provider
    }

    func fetch() async -> ProviderUsageResult {
        hasStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        do {
            try await Task.sleep(for: .seconds(60))
            return .failed(provider, "Fetcher unexpectedly completed without cancellation")
        } catch {
            observedCancellation = Task.isCancelled
            cancellationWaiters.forEach { $0.resume() }
            cancellationWaiters.removeAll()
            return .unavailable(provider)
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationIsObserved() async {
        guard !observedCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }
}

@MainActor
final class ProviderUsageStoreTests: XCTestCase {
    func testConstructionDoesNoProviderWorkAndEachExplicitRefreshFetchesOnce() async {
        let claude = CountingProviderUsageFetcher(
            provider: .claude,
            result: .unavailable(.claude)
        )
        let codex = CountingProviderUsageFetcher(
            provider: .codex,
            result: .unavailable(.codex)
        )
        let store = ProviderUsageStore(fetchers: [claude, codex])

        let initialClaudeCallCount = await claude.callCount
        let initialCodexCallCount = await codex.callCount
        XCTAssertEqual(initialClaudeCallCount, 0)
        XCTAssertEqual(initialCodexCallCount, 0)
        XCTAssertTrue(store.results.isEmpty)

        await store.refresh()

        let firstClaudeCallCount = await claude.callCount
        let firstCodexCallCount = await codex.callCount
        XCTAssertEqual(firstClaudeCallCount, 1)
        XCTAssertEqual(firstCodexCallCount, 1)

        await store.refresh()

        let secondClaudeCallCount = await claude.callCount
        let secondCodexCallCount = await codex.callCount
        XCTAssertEqual(secondClaudeCallCount, 2)
        XCTAssertEqual(secondCodexCallCount, 2)
    }

    func testRefreshPublishesStableProviderOrderAndDeduplicatesByProvider() async {
        let codex = CountingProviderUsageFetcher(
            provider: .codex,
            result: .failed(.codex, "first Codex result")
        )
        let firstClaude = CountingProviderUsageFetcher(
            provider: .claude,
            result: .failed(.claude, "stale Claude result")
        )
        let lastClaude = CountingProviderUsageFetcher(
            provider: .claude,
            result: .unavailable(.claude)
        )
        let store = ProviderUsageStore(fetchers: [codex, firstClaude, lastClaude])

        await store.refresh()

        XCTAssertEqual(store.results.map(\.provider), [.claude, .codex])
        guard case .unavailable(.claude) = store.results.first else {
            return XCTFail("The last result for a duplicate provider must win within one refresh")
        }
    }

    func testOlderRefreshCannotOverwriteANewerGeneration() async {
        let fetcher = ControllableProviderUsageFetcher(provider: .codex)
        let store = ProviderUsageStore(fetchers: [fetcher])

        let olderRefresh = Task { await store.refresh() }
        await fetcher.waitUntilCallCount(1)
        let newerRefresh = Task { await store.refresh() }
        await fetcher.waitUntilCallCount(2)

        await fetcher.complete(callID: 1, with: .unavailable(.codex))
        await newerRefresh.value
        await fetcher.complete(callID: 0, with: .failed(.codex, "stale failure"))
        await olderRefresh.value

        XCTAssertFalse(store.isRefreshing)
        guard case .unavailable(.codex) = store.results.first else {
            return XCTFail("A late completion from an older refresh must not overwrite newer provider state")
        }
    }

    func testCancellingRefreshStopsProviderWorkWithoutPublishingItsCancellationResult() async {
        let fetcher = CancellationObservingProviderUsageFetcher(provider: .codex)
        let store = ProviderUsageStore(fetchers: [fetcher])

        let refresh = Task { await store.refresh() }
        await fetcher.waitUntilStarted()
        XCTAssertTrue(store.isRefreshing)

        store.cancelRefresh()
        await fetcher.waitUntilCancellationIsObserved()
        await refresh.value

        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(
            store.results.isEmpty,
            "A provider result produced while unwinding cancellation must not become visible after the popover closes"
        )
    }
}

@MainActor
final class SidebarQuotaPresentationTests: XCTestCase {
    private func snapshot(
        provider: ProviderUsageProvider,
        windowCount: Int = 1
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            windows: (0..<windowCount).map { index in
                ProviderUsageWindow(
                    id: "\(provider).\(index)",
                    label: index.isMultiple(of: 2) ? "5h" : "7d",
                    usedPercent: 17 + index,
                    resetsAt: Date(timeIntervalSince1970: 1_785_171_600 + Double(index * 3_600))
                )
            }
        )
    }

    func testSignedOutProvidersAreOmittedWhileSignedInFetchFailuresRemainVisible() {
        let claude = snapshot(provider: .claude)

        let signedOutPresentation = SidebarQuotaPresentation(
            results: [.available(claude), .unavailable(.codex)]
        )
        XCTAssertEqual(signedOutPresentation.availableSnapshots.map(\.provider), [.claude])
        XCTAssertTrue(signedOutPresentation.unavailableProviders.isEmpty)

        let failedPresentation = SidebarQuotaPresentation(
            results: [.available(claude), .failed(.codex, "Codex usage could not be read.")]
        )
        XCTAssertEqual(failedPresentation.failures.map(\.provider), [.codex])
        XCTAssertEqual(failedPresentation.failures.first?.message, "Codex usage could not be read.")
    }

    func testEmptyStateAppearsOnlyWhenNoAvailableUsageOrGenuineFailureExists() {
        let allSignedOut = SidebarQuotaPresentation(
            results: [.unavailable(.claude), .unavailable(.codex)]
        )
        XCTAssertTrue(allSignedOut.showsEmptyState)
        XCTAssertTrue(allSignedOut.unavailableProviders.isEmpty)

        let genuineFailure = SidebarQuotaPresentation(
            results: [.unavailable(.claude), .failed(.codex, "Authenticated read failed")]
        )
        XCTAssertFalse(
            genuineFailure.showsEmptyState,
            "A visible authenticated-provider failure must not be mislabeled as no usage available"
        )
        XCTAssertEqual(genuineFailure.failures.map(\.provider), [.codex])
    }

    func testPopoverFittingHeightTracksVisibleContentAndCapsOversizedResults() async {
        let oneProviderHeight = await fittingHeight(
            results: [.available(snapshot(provider: .claude, windowCount: 2))]
        )
        let twoProviderHeight = await fittingHeight(
            results: [
                .available(snapshot(provider: .claude, windowCount: 2)),
                .available(snapshot(provider: .codex, windowCount: 2)),
            ]
        )
        let oversizedHeight = await fittingHeight(
            results: [.available(snapshot(provider: .codex, windowCount: 30))]
        )

        XCTAssertLessThan(oneProviderHeight, twoProviderHeight)
        XCTAssertLessThan(oneProviderHeight, 340)
        XCTAssertLessThan(twoProviderHeight, 360)
        XCTAssertGreaterThan(oversizedHeight, twoProviderHeight)
        XCTAssertLessThanOrEqual(oversizedHeight, 480)
    }

    func testOpenPopoverResizesWhenLoadingBecomesProviderResults() async throws {
        let fetcher = ControllableProviderUsageFetcher(provider: .claude)
        let store = ProviderUsageStore(fetchers: [fetcher])
        let refresh = Task { await store.refresh() }
        await fetcher.waitUntilCallCount(1)
        let sizingDriver = SidebarPopoverSizingTestDriver(
            rootView: AnyView(SidebarQuotaFooter(store: store))
        )
        let loadingSize = sizingDriver.installPopover()

        await fetcher.complete(
            callID: 0,
            with: .available(snapshot(provider: .claude, windowCount: 2))
        )
        await refresh.value
        sizingDriver.updateRootView(AnyView(SidebarQuotaFooter(store: store)))
        let resultsSize = try XCTUnwrap(sizingDriver.contentSize)

        XCTAssertNotEqual(loadingSize.height, resultsSize.height)
        XCTAssertLessThan(resultsSize.height, 340)
    }

    func testHelpPopoverKeepsANonzeroNaturalFittingSize() {
        let size = SidebarHelpPopoverSizingTestDriver.fittingSize()

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testUsagePopoverDoesNotExposeAManualRefreshControl() {
        XCTAssertFalse(
            SidebarQuotaFooter.showsManualRefreshControl,
            "Opening the popover performs the refresh; a second refresh control makes freshness ambiguous"
        )
    }

    func testFooterControlsKeepAccessibleTargetsOnATrafficLightVisualPitch() {
        let buttonSize = SidebarFooterControlLayout.buttonSize
        let helpCenter = buttonSize / 2
            + SidebarFooterControlLayout.helpIconOffset(clustersWithUsage: true)
        let usageCenter = buttonSize + buttonSize / 2
            + SidebarFooterControlLayout.usageIconOffset

        XCTAssertGreaterThanOrEqual(buttonSize, 44)
        XCTAssertEqual(usageCenter - helpCenter, SidebarFooterControlLayout.visualPitch)
        XCTAssertEqual(SidebarFooterControlLayout.helpIconOffset(clustersWithUsage: false), 0)
    }

    private func fittingHeight(results: [ProviderUsageResult]) async -> CGFloat {
        let fetchers: [any ProviderUsageFetching] = results.map { result in
            CountingProviderUsageFetcher(provider: result.provider, result: result)
        }
        let store = ProviderUsageStore(fetchers: fetchers)
        await store.refresh()
        let controller = NSHostingController(rootView: SidebarQuotaFooter(store: store))
        controller.view.layoutSubtreeIfNeeded()
        return ceil(controller.view.fittingSize.height)
    }
}
