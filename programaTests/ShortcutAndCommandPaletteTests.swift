import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class SplitShortcutTransientFocusGuardTests: XCTestCase {
    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsTiny() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsDetached() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: false
            )
        )
    }

    func testAllowsWhenFirstResponderFallsBackButGeometryIsHealthy() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testAllowsWhenFirstResponderIsTerminalEvenIfViewIsTiny() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: false,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }
}



final class FullScreenShortcutTests: XCTestCase {
    func testMatchesCommandControlF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testMatchesCommandControlFFromKeyCodeWhenCharsAreUnavailable() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testDoesNotFallbackToANSIWhenLayoutTranslationReturnsNonFCharacter() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in "u" }
            )
        )
    }

    func testMatchesCommandControlFWhenCommandAwareLayoutTranslationProvidesF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, modifierFlags in
                    modifierFlags.contains(.command) ? "f" : "u"
                }
            )
        )
    }

    func testMatchesCommandControlFWhenCharsAreControlSequence() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "\u{06}",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testRejectsPhysicalFWhenCharacterRepresentsDifferentLayoutKey() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "u",
                keyCode: 3
            )
        )
    }

    func testIgnoresCapsLockForCommandControlF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .capsLock],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsWhenControlIsMissing() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsAdditionalModifiers() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .shift],
                chars: "f",
                keyCode: 3
            )
        )
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .option],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsWhenCommandIsMissing() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.control],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsNonFKey() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "r",
                keyCode: 15
            )
        )
    }
}


final class CommandPaletteKeyboardNavigationTests: XCTestCase {
    func testArrowKeysMoveSelectionWithoutModifiers() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 125
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 126
            ),
            -1
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.shift],
                chars: "",
                keyCode: 125
            )
        )
    }

    func testControlLetterNavigationSupportsPrintableAndControlCharsForNPOnly() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "n",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0e}",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "p",
                keyCode: 35
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{10}",
                keyCode: 35
            ),
            -1
        )
    }

    func testDoesNotTreatControlJKAsPaletteNavigation() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "j",
                keyCode: 38
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0a}",
                keyCode: 38
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "k",
                keyCode: 40
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0b}",
                keyCode: 40
            )
        )
    }

    func testIgnoresUnsupportedModifiersAndKeys() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control, .shift],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "x",
                keyCode: 7
            )
        )
    }

    func testInlineTextHandlingDisablesPaletteSelectionNavigationRouting() {
        XCTAssertTrue(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: -1,
                isInteractive: true,
                usesInlineTextHandling: false
            )
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: -1,
                isInteractive: true,
                usesInlineTextHandling: true
            )
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: nil,
                isInteractive: true,
                usesInlineTextHandling: false
            )
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: 1,
                isInteractive: false,
                usesInlineTextHandling: false
            )
        )
    }
}


final class CommandPaletteOpenShortcutConsumptionTests: XCTestCase {
    func testDoesNotConsumeWhenPaletteIsNotVisible() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: false,
                normalizedFlags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
    }

    func testConsumesAppCommandShortcutsWhenPaletteIsVisible() {
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "t",
                keyCode: 17
            )
        )
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command, .shift],
                chars: ",",
                keyCode: 43
            )
        )
    }

    func testAllowsClipboardAndUndoShortcutsForPaletteTextEditing() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "v",
                keyCode: 9
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "z",
                keyCode: 6
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command, .shift],
                chars: "z",
                keyCode: 6
            )
        )
    }

    func testAllowsArrowAndDeleteEditingCommandsForPaletteTextEditing() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "",
                keyCode: 123
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "",
                keyCode: 51
            )
        )
    }

    func testConsumesEscapeWhenPaletteIsVisible() {
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [],
                chars: "",
                keyCode: 53
            )
        )
    }
}


final class CommandPaletteFocusStealerClassificationTests: XCTestCase {
    private final class NonViewTextDelegate: NSObject, NSTextViewDelegate {}
    private final class UnrelatedViewTextDelegate: NSView, NSTextViewDelegate {}

    func testTreatsGhosttySurfaceViewAsFocusStealer() {
        let surfaceView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))

        XCTAssertTrue(isCommandPaletteFocusStealingTerminalResponder(surfaceView))
    }

    func testTreatsTextFieldInsideTerminalHostedViewAsFocusStealer() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        hostedView.addSubview(textField)

        XCTAssertTrue(
            isCommandPaletteFocusStealingTerminalResponder(textField),
            "Terminal-owned overlay text inputs should not be allowed to reclaim focus from the command palette"
        )
    }

    func testDoesNotTreatUnrelatedTextFieldAsFocusStealer() {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertFalse(isCommandPaletteFocusStealingTerminalResponder(textField))
    }

    func testTreatsTextViewInsideTerminalHostedViewAsFocusStealerWhenDelegateIsNotAView() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let delegate = NonViewTextDelegate()
        textView.delegate = delegate
        hostedView.addSubview(textView)

        XCTAssertTrue(
            isCommandPaletteFocusStealingTerminalResponder(textView),
            "NSTextView responders should still be blocked via the NSView hierarchy walk when the delegate is not a view"
        )
    }

    func testTreatsTextViewInsideTerminalHostedViewAsFocusStealerWhenDelegateViewIsUnrelated() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let delegateView = UnrelatedViewTextDelegate(frame: .zero)
        textView.delegate = delegateView
        hostedView.addSubview(textView)

        XCTAssertTrue(
            isCommandPaletteFocusStealingTerminalResponder(textView),
            "NSTextView responders should still be blocked via the NSView hierarchy walk when the delegate view is unrelated"
        )
    }
}




final class CommandPaletteSelectionScrollBehaviorTests: XCTestCase {
    func testFirstEntryPinsToTopAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.top)
    }

    func testLastEntryPinsToBottomAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 19,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.bottom)
    }

    func testMiddleEntryUsesNilAnchorForMinimalScroll() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 6,
            resultCount: 20
        )
        XCTAssertNil(anchor)
    }

    func testEmptyResultsProduceNoAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 0
        )
        XCTAssertNil(anchor)
    }
}


final class ShortcutHintModifierPolicyTests: XCTestCase {
    func testShortcutHintRequiresCommandOnlyModifier() {
        XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: []))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .shift]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control, .shift]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .option]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control, .option]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .control]))
    }

    func testShortcutHintStaysCommandOnlyWhenWorkspaceShortcutIsCustomized() {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            for: action
        )

        XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command]))
        XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control]))
    }

    func testShortcutHintUsesIntentionalHoldDelay() {
        XCTAssertEqual(ShortcutHintModifierPolicy.intentionalHoldDelay, 0.30, accuracy: 0.001)
    }

    func testCurrentWindowRequiresHostWindowToBeKeyAndMatchEventWindow() {
        XCTAssertTrue(
            ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 7,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: false,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )
    }

    func testWindowScopedShortcutHintsUseKeyWindowWhenNoEventWindowIsAvailable() {
        XCTAssertTrue(
            ShortcutHintModifierPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 7
            )
        )

        XCTAssertTrue(
            ShortcutHintModifierPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            ShortcutHintModifierPolicy.shouldShowHints(
                for: [.control],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 42
            )
        )
    }
}


final class ShortcutHintDebugSettingsTests: XCTestCase {
    func testClampKeepsValuesWithinSupportedRange() {
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(0.0), 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(4.0), 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(-100.0), ShortcutHintDebugSettings.offsetRange.lowerBound)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(100.0), ShortcutHintDebugSettings.offsetRange.upperBound)
    }

    func testDefaultOffsetsMatchCurrentBadgePlacements() {
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintX, 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintY, 0.0)
        XCTAssertFalse(ShortcutHintDebugSettings.defaultAlwaysShowHints)
    }

    func testResetVisibilityDefaultsRestoresAlwaysShowFlag() {
        let suiteName = "ShortcutHintDebugSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: ShortcutHintDebugSettings.alwaysShowHintsKey)

        ShortcutHintDebugSettings.resetVisibilityDefaults(defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: ShortcutHintDebugSettings.alwaysShowHintsKey) as? Bool,
            ShortcutHintDebugSettings.defaultAlwaysShowHints
        )
    }
}


final class DevBuildBannerDebugSettingsTests: XCTestCase {
    func testShowSidebarBannerDefaultsToVisible() {
        let suiteName = "DevBuildBannerDebugSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertTrue(DevBuildBannerDebugSettings.showSidebarBanner(defaults: defaults))
    }

    func testShowSidebarBannerRespectsStoredValue() {
        let suiteName = "DevBuildBannerDebugSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertFalse(DevBuildBannerDebugSettings.showSidebarBanner(defaults: defaults))

        defaults.set(true, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        XCTAssertTrue(DevBuildBannerDebugSettings.showSidebarBanner(defaults: defaults))
    }
}


final class ShortcutHintLanePlannerTests: XCTestCase {
    func testAssignLanesKeepsSeparatedIntervalsOnSingleLane() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 28...40, 48...64]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 0, 0])
    }

    func testAssignLanesStacksOverlappingIntervalsIntoAdditionalLanes() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 22...38, 40...56]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 1, 2, 0])
    }
}


final class ShortcutHintHorizontalPlannerTests: XCTestCase {
    func testAssignRightEdgesResolvesOverlapWithMinimumSpacing() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 30...46]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 6)

        XCTAssertEqual(rightEdges.count, intervals.count)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[1].lowerBound - adjustedIntervals[0].upperBound, 6)
        XCTAssertGreaterThanOrEqual(adjustedIntervals[2].lowerBound - adjustedIntervals[1].upperBound, 6)
    }

    func testAssignRightEdgesKeepsAlreadySeparatedIntervalsInPlace() {
        let intervals: [ClosedRange<CGFloat>] = [0...12, 20...32, 40...52]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 4)
        XCTAssertEqual(rightEdges, [12, 32, 52])
    }
}


final class AppearanceSettingsTests: XCTestCase {
    func testResolvedModeDefaultsToSystemWhenUnset() {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)

        let resolved = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(resolved, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
    }
}


final class QuitWarningSettingsTests: XCTestCase {
    func testDefaultWarnBeforeQuitIsEnabledWhenUnset() {
        let suiteName = "QuitWarningSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: QuitWarningSettings.warnBeforeQuitKey)

        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "QuitWarningSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertFalse(QuitWarningSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }
}


final class UpdateChannelSettingsTests: XCTestCase {
    func testResolvedFeedFallsBackWhenInfoFeedMissing() {
        let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: nil)
        XCTAssertEqual(resolved.url, UpdateFeedResolver.fallbackFeedURL)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedFallsBackWhenInfoFeedEmpty() {
        let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: "")
        XCTAssertEqual(resolved.url, UpdateFeedResolver.fallbackFeedURL)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedUsesInfoFeedURLWhenPresent() {
        let infoFeed = "https://example.com/custom/appcast.xml"
        let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: infoFeed)
        XCTAssertEqual(resolved.url, infoFeed)
        XCTAssertFalse(resolved.usedFallback)
    }
}


private final class UpdateRelaunchPreparationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var operationRanOnMainThread = false

    func recordPrepared() {
        lock.lock()
        operationRanOnMainThread = Thread.isMainThread
        events.append("prepared")
        lock.unlock()
    }

    func recordReturned() {
        lock.lock()
        events.append("returned")
        lock.unlock()
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> (events: [String], operationRanOnMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (events, operationRanOnMainThread)
    }
}


final class UpdateRelaunchPreparationTests: XCTestCase {
    @MainActor
    func testMainThreadCallCompletesPreparationBeforeReturning() {
        var events: [String] = []
        var operationRanOnMainThread = false

        UpdateRelaunchPreparation.performSynchronously {
            operationRanOnMainThread = Thread.isMainThread
            events.append("prepared")
        }
        events.append("returned")

        XCTAssertEqual(events, ["prepared", "returned"])
        XCTAssertTrue(operationRanOnMainThread)
    }

    @MainActor
    func testBackgroundCallCompletesMainThreadPreparationBeforeReturning() async {
        let recorder = UpdateRelaunchPreparationRecorder()
        let completed = expectation(description: "background relaunch preparation completed")

        DispatchQueue.global(qos: .userInitiated).async {
            UpdateRelaunchPreparation.performSynchronously {
                recorder.recordPrepared()
            }
            recorder.recordReturned()
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events, ["prepared", "returned"])
        XCTAssertTrue(snapshot.operationRanOnMainThread)
    }

    func testSynchronousPersistenceWriteDrainsEarlierQueuedWriteBeforeReturning() async {
        let queue = DispatchQueue(label: "test.update-relaunch.persistence-order")
        let recorder = UpdateRelaunchPreparationRecorder()
        let completed = expectation(description: "synchronous persistence write completed")

        queue.suspend()
        queue.async {
            recorder.record("earlier")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            AppDelegate.performSessionPersistenceWrite(on: queue, synchronously: true) {
                recorder.record("final")
            }
            recorder.recordReturned()
            completed.fulfill()
        }
        queue.resume()

        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(recorder.snapshot().events, ["earlier", "final", "returned"])
    }
}


final class UpdateSettingsTests: XCTestCase {
    func testApplyEnablesAutomaticChecksAndDailySchedule() {
        let defaults = makeDefaults()
        UpdateSettings.apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        XCTAssertEqual(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey), UpdateSettings.scheduledCheckInterval)
        // Silent auto-install became the default 2026-08-20 (audit follow-up).
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.sendProfileInfoKey))
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.migrationKey))
    }

    func testAutoInstallMigrationFlipsStoredFalseOnceAndRespectsLaterUserChoice() {
        let defaults = makeDefaults()
        // The v2 migration wrote a concrete false into existing installs.
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)

        UpdateSettings.apply(to: defaults)
        XCTAssertTrue(
            defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey),
            "the v3 migration must clear the v2-era stored false so the new registered default applies"
        )
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.autoInstallMigrationKey))

        // A user turning it off AFTER the migration is a real choice and must survive.
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        UpdateSettings.apply(to: defaults)
        XCTAssertFalse(
            defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey),
            "the migration must run once — a post-migration user choice wins"
        )
    }

    func testApplyRepairsLegacyDisabledAutomaticChecksOnce() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        defaults.set(0, forKey: UpdateSettings.scheduledCheckIntervalKey)
        defaults.set(true, forKey: UpdateSettings.automaticallyUpdateKey)

        UpdateSettings.apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        XCTAssertEqual(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey), UpdateSettings.scheduledCheckInterval)
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))

        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        UpdateSettings.apply(to: defaults)

        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class UpdateViewModelPresentationTests: XCTestCase {
    func testDetectedBackgroundUpdateShowsPillWhileIdle() {
        let viewModel = UpdateViewModel()

        viewModel.detectedUpdateVersion = "9.9.9"

        XCTAssertTrue(viewModel.showsPill)
        XCTAssertTrue(viewModel.showsDetectedBackgroundUpdate)
        XCTAssertEqual(viewModel.text, "Update Available: 9.9.9")
        XCTAssertEqual(viewModel.iconName, "shippingbox.fill")
    }

    func testActiveUpdateStateTakesPrecedenceOverDetectedBackgroundVersion() {
        let viewModel = UpdateViewModel()

        viewModel.detectedUpdateVersion = "9.9.9"
        viewModel.state = .checking(.init(cancel: {}))

        XCTAssertTrue(viewModel.showsPill)
        XCTAssertFalse(viewModel.showsDetectedBackgroundUpdate)
        XCTAssertEqual(viewModel.text, "Checking for Updates…")
    }
}

@MainActor
final class CommandPaletteOverlayPromotionPolicyTests: XCTestCase {
    func testShouldPromoteWhenBecomingVisible() {
        XCTAssertTrue(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: false,
                isVisible: true
            )
        )
    }

    func testShouldNotPromoteWhenAlreadyVisible() {
        XCTAssertFalse(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: true,
                isVisible: true
            )
        )
    }

    func testShouldNotPromoteWhenHidden() {
        XCTAssertFalse(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: true,
                isVisible: false
            )
        )
        XCTAssertFalse(
            CommandPaletteOverlayPromotionPolicy.shouldPromote(
                previouslyVisible: false,
                isVisible: false
            )
        )
    }
}

@MainActor
final class CommandPaletteLifecycleOwnerTests: XCTestCase {
    func testWindowLifecycleExpiresPendingRequestsAndEscapeSuppression() {
        let lifecycle = CommandPaletteWindowLifecycle()
        let windowId = UUID()

        lifecycle.markOpenRequested(windowId: windowId, now: 10)
        XCTAssertTrue(lifecycle.isPendingOpen(windowId: windowId, now: 11, maximumAge: 2))
        XCTAssertFalse(lifecycle.isPendingOpen(windowId: windowId, now: 13, maximumAge: 2))

        lifecycle.beginEscapeSuppression(windowId: windowId, now: 20)
        XCTAssertTrue(lifecycle.shouldConsumeSuppressedEscape(windowId: windowId, now: 20.2))
        XCTAssertFalse(lifecycle.shouldConsumeSuppressedEscape(windowId: windowId, now: 20.5))
    }

    func testWindowLifecycleTracksVisibilitySelectionAndTeardown() {
        let lifecycle = CommandPaletteWindowLifecycle()
        let windowId = UUID()

        XCTAssertFalse(lifecycle.setVisible(true, windowId: windowId))
        XCTAssertTrue(lifecycle.isVisible(windowId: windowId))
        lifecycle.setSelectionIndex(-4, windowId: windowId)
        XCTAssertEqual(lifecycle.selectionIndex(windowId: windowId), 0)
        XCTAssertTrue(lifecycle.setVisible(false, windowId: windowId))
        lifecycle.teardown(windowId: windowId)
        XCTAssertFalse(lifecycle.isVisible(windowId: windowId))
    }

    func testControllerOwnsSelectionAndUsageTransitions() {
        let controller = CommandPaletteController()

        XCTAssertTrue(controller.moveSelection(by: 1, resultIDs: ["one", "two", "three"]))
        XCTAssertEqual(controller.commandPaletteSelectedResultIndex, 1)
        XCTAssertEqual(controller.commandPaletteSelectionAnchorCommandID, "two")
        XCTAssertFalse(controller.moveSelection(by: 1, resultIDs: []))

        let first = controller.recordUsage(commandId: "open", usedAt: 10)
        let second = controller.recordUsage(commandId: "open", usedAt: 20)
        XCTAssertEqual(first["open"]?.useCount, 1)
        XCTAssertEqual(second["open"]?.useCount, 2)
        XCTAssertEqual(second["open"]?.lastUsedAt, 20)
    }
}
