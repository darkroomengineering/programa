import XCTest
import AppKit
import WebKit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Clicking into an inactive Programa window activates the window without also
/// focusing the pane under the pointer. That used to be a preference
/// (`paneFirstClickFocus.enabled`); it is now the only behaviour, so these
/// tests pin it rather than exercising both sides of a toggle.
///
/// The three view classes are covered separately because each one used to
/// override `acceptsFirstMouse` on its own, and a future override on any of
/// them would silently reintroduce click-through.
@MainActor
final class InactivePaneFirstClickFocusTests: XCTestCase {
    /// Set by nothing now. Asserting the views ignore it is what proves the
    /// preference is genuinely gone rather than merely hidden from Settings.
    private let removedSettingsKey = "paneFirstClickFocus.enabled"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: removedSettingsKey)
        super.tearDown()
    }

    func testTerminalViewRejectsFirstMouse() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }


    func testMarkdownPointerObserverRejectsFirstMouse() {
        let view = MarkdownPanelPointerObserverView(frame: .zero)

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testRemovedPreferenceNoLongerEnablesClickThrough() {
        // The old key turning click-through back on is the regression this
        // guards: leaving a live read behind would make the setting removal
        // cosmetic for anyone whose settings.json still carries it.
        UserDefaults.standard.set(true, forKey: removedSettingsKey)

        XCTAssertFalse(GhosttyNSView(frame: .zero).acceptsFirstMouse(for: nil))
        XCTAssertFalse(MarkdownPanelPointerObserverView(frame: .zero).acceptsFirstMouse(for: nil))
    }

    func testMarkdownPointerObserverStaysOutOfHitTesting() {
        let view = MarkdownPanelPointerObserverView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
    }
}
