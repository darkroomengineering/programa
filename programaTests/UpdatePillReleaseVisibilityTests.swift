import XCTest
import Foundation
import AppKit
import Sparkle
import Sparkle_Private.SUAppcastItem

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class UpdateReleaseNotesDestinationTests: XCTestCase {
    private func update(primary: String? = nil, full: String? = nil) throws -> UpdateState.UpdateAvailable {
        var dictionary: [String: Any] = [
            "title": "Programa 0.4.213",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/programa.zip", "length": "1024",
                "sparkle:version": "213", "sparkle:shortVersionString": "0.4.213"
            ]
        ]
        if let primary { dictionary["sparkle:releaseNotesLink"] = ["content": primary] }
        if let full { dictionary["sparkle:fullReleaseNotesLink"] = full }
        let comparator = SUStandardVersionComparator.default
        let resolver = SPUAppcastItemStateResolver(hostVersion: "1",
            applicationVersionComparator: comparator, standardVersionComparator: comparator)
        let item = try XCTUnwrap(SUAppcastItem(dictionary: dictionary, relativeTo: nil,
            stateResolver: resolver, signingValidationStatus: .skipped, failureReason: nil))
        return UpdateState.UpdateAvailable(appcastItem: item, reply: { _ in })
    }

    func testPrimaryAppcastReleaseNotesTakePrecedence() throws {
        let primary = "https://example.com/rolling/current-notes"
        let available = try update(primary: primary, full: "https://example.com/all-notes")
        XCTAssertEqual(available.releaseNotes?.url.absoluteString, primary,
                       "Rolling versions must use the publisher's actual notes instead of inventing a version tag")
    }

    func testFullAppcastReleaseNotesAreUsedWhenPrimaryIsAbsent() throws {
        let full = "https://example.com/all-notes"
        XCTAssertEqual(try update(full: full).releaseNotes?.url.absoluteString, full)
    }

    func testSemanticVersionWithoutAppcastNotesDoesNotInventADestination() throws {
        XCTAssertNil(try update().releaseNotes,
                     "A version number does not establish that a corresponding release tag exists")
    }
}

final class BrowserInsecureHTTPSettingsTests: XCTestCase {
    func testDefaultAllowlistPatternsArePresent() {
        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: nil),
            ["localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]
        )
    }

    func testWildcardAndExactHostMatching() {
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("localhost", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("127.0.0.1", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("::1", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("0.0.0.0", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("api.localtest.me", rawAllowlist: nil))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("neverssl.com", rawAllowlist: nil))
    }

    func testCustomAllowlistNormalizesAndDeduplicatesEntries() {
        let raw = """
        localhost
        *.example.com
        127.0.0.1
        https://dev.internal:8080/path
        *.example.com
        """

        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: raw),
            ["localhost", "*.example.com", "127.0.0.1", "dev.internal"]
        )
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("foo.example.com", rawAllowlist: raw))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("dev.internal", rawAllowlist: raw))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("example.net", rawAllowlist: raw))
    }

    func testBlockDecisionUsesAllowlistAndSchemeRules() throws {
        let localURL = try XCTUnwrap(URL(string: "http://foo.localtest.me:3000"))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(localURL, rawAllowlist: nil))

        let insecureURL = try XCTUnwrap(URL(string: "http://neverssl.com"))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(insecureURL, rawAllowlist: nil))

        let httpsURL = try XCTUnwrap(URL(string: "https://neverssl.com"))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(httpsURL, rawAllowlist: nil))
    }

    func testPreparedNavigationRequestPreservesOriginalMethodBodyAndHeaders() throws {
        let url = try XCTUnwrap(URL(string: "http://localtest.me:3000/submit"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("token=abc123".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let prepared = browserPreparedNavigationRequest(request)

        XCTAssertEqual(prepared.url, url)
        XCTAssertEqual(prepared.httpMethod, "POST")
        XCTAssertEqual(prepared.httpBody, Data("token=abc123".utf8))
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(prepared.cachePolicy, .useProtocolCachePolicy)
    }

    func testOneTimeBypassIsConsumedAfterFirstNavigation() throws {
        let insecureURL = try XCTUnwrap(URL(string: "http://neverssl.com"))
        var bypassHostOnce: String? = "neverssl.com"

        XCTAssertTrue(browserShouldConsumeOneTimeInsecureHTTPBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        XCTAssertNil(bypassHostOnce)

        // Subsequent visits should prompt again unless host was saved.
        XCTAssertFalse(browserShouldConsumeOneTimeInsecureHTTPBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(insecureURL, rawAllowlist: nil))
    }

    func testAddAllowedHostPersistsToDefaultsAndUnblocksHTTP() throws {
        let suiteName = "BrowserInsecureHTTPSettingsTests.Persist.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = try XCTUnwrap(URL(string: "http://persist-me.test"))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(url, defaults: defaults))

        BrowserInsecureHTTPSettings.addAllowedHost("persist-me.test", defaults: defaults)
        let persisted = defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
        XCTAssertNotNil(persisted)
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("persist-me.test", defaults: defaults))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(url, defaults: defaults))
    }

    func testAllowlistSelectionPersistsForProceedAndOpenExternal() {
        XCTAssertTrue(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertFirstButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertTrue(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertFalse(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertThirdButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertFalse(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: false
        ))
    }
}

final class TitlebarControlsSizingPolicyTests: XCTestCase {
    func testSchedulePolicyRequiresMeaningfulViewSizeChange() {
        XCTAssertFalse(titlebarControlsShouldScheduleForViewSizeChange(previous: .zero, current: .zero))
        XCTAssertTrue(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: .zero,
                current: NSSize(width: 240, height: 38)
            )
        )
        XCTAssertFalse(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 240.2, height: 38.1)
            )
        )
        XCTAssertTrue(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 247, height: 38)
            )
        )
    }

    func testLayoutApplyPolicySkipsEquivalentSnapshots() {
        let baseline = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 128, height: 22),
            containerHeight: 28,
            yOffset: 3
        )
        XCTAssertTrue(titlebarControlsShouldApplyLayout(previous: nil, next: baseline))
        XCTAssertFalse(titlebarControlsShouldApplyLayout(previous: baseline, next: baseline))

        let changed = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 132, height: 22),
            containerHeight: 28,
            yOffset: 3
        )
        XCTAssertTrue(titlebarControlsShouldApplyLayout(previous: baseline, next: changed))
    }

    func testShortcutHintVerticalOffsetKeepsPillInsideButtonLane() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let hintHeight = titlebarShortcutHintHeight(for: config)
            let verticalOffset = titlebarShortcutHintVerticalOffset(for: config)

            XCTAssertGreaterThanOrEqual(verticalOffset, 0, "Expected non-negative hint offset for style \(style)")
            XCTAssertLessThanOrEqual(
                verticalOffset + hintHeight,
                config.buttonSize,
                "Expected hint pill to fit within the titlebar button lane for style \(style)"
            )
        }
    }
}

final class TitlebarControlsHoverPolicyTests: XCTestCase {
    /// Every titlebar control style now tracks hover.
    ///
    /// This previously asserted that only `pillGroup` did, which meant the
    /// default (`classic`) titlebar buttons gave no feedback at all — they did
    /// not respond to the cursor, unlike every other piece of macOS window
    /// chrome. Hover and press feedback are now part of the shared control
    /// style, so the presets differ only in size and spacing, never in whether
    /// they react to input.
    func testHoverTrackingEnabledForEveryStyle() {
        XCTAssertTrue(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.classic.config))
        XCTAssertTrue(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.compact.config))
        XCTAssertTrue(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.roomy.config))
        XCTAssertTrue(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.pillGroup.config))
        XCTAssertTrue(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.softButtons.config))
    }
}

/// Tests for the predicate that suppresses the Sparkle updater in non-release builds.
///
/// Tagged DEV builds and staging builds must never start the public update feed
/// so users don't see a spurious "Update Available" pill. This suite exercises
/// the pure function that gates `startUpdaterIfNeeded()` — no Sparkle or app
/// objects are created, so the tests run fast and without side effects.
final class UpdateControllerStartupSuppressTests: XCTestCase {

    // MARK: — debug bundle identifiers

    func testUntaggedDebugBundleIdentifierSuppressesUpdater() {
        XCTAssertTrue(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.darkroom.programa.debug"),
            "Untagged debug build must not start Sparkle"
        )
    }

    func testTaggedDebugBundleIdentifierSuppressesUpdater() {
        XCTAssertTrue(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.darkroom.programa.debug.fix-some-bug"),
            "Tagged DEV build must not start Sparkle"
        )
    }

    func testDebugBundleIdentifierWithNumericTagSuppressesUpdater() {
        XCTAssertTrue(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.darkroom.programa.debug.1"),
            "Tagged DEV build with numeric tag must not start Sparkle"
        )
    }

    // MARK: — staging bundle identifiers

    func testStagingBundleIdentifierSuppressesUpdater() {
        XCTAssertTrue(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.darkroom.programa.staging"),
            "Staging build must not start Sparkle"
        )
    }

    func testTaggedStagingBundleIdentifierSuppressesUpdater() {
        XCTAssertTrue(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.darkroom.programa.staging.qa"),
            "Tagged staging build must not start Sparkle"
        )
    }

    // MARK: — release bundle identifiers

    func testProductionBundleIdentifierDoesNotSuppressUpdater() {
        XCTAssertFalse(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.darkroom.programa"),
            "Release build must start Sparkle normally"
        )
    }

    func testNilBundleIdentifierDoesNotSuppressUpdater() {
        XCTAssertFalse(
            updateControllerShouldSkipStartup(bundleIdentifier: nil),
            "nil bundle identifier must not suppress the updater (fail-open to release behaviour)"
        )
    }

    func testUnrelatedBundleIdentifierDoesNotSuppressUpdater() {
        XCTAssertFalse(
            updateControllerShouldSkipStartup(bundleIdentifier: "com.example.app"),
            "Unrelated bundle identifier must not suppress the updater"
        )
    }
}
