import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

@MainActor
final class ProgramaLayoutFileIdentityTests: XCTestCase {
    private let layout = ProgramaLayoutNode.pane(ProgramaPaneDefinition(surfaces: [
        ProgramaSurfaceDefinition(type: .terminal, name: nil, command: nil, cwd: nil, env: nil, url: nil, focus: nil)
    ]))

    func testCopiedAndRenamedLayoutsUseDistinctFilenameIdentities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ProgramaLayoutStore(directoryURL: directory, startWatching: false)
        let original = URL(fileURLWithPath: try writer.save(name: "original", layout: layout, force: false))
        let copied = directory.appendingPathComponent("copied layout.json")
        try FileManager.default.copyItem(at: original, to: copied)
        try FileManager.default.moveItem(at: original, to: directory.appendingPathComponent("renamed.json"))
        let reader = ProgramaLayoutStore(directoryURL: directory, startWatching: false)
        XCTAssertEqual(Set(reader.list().map(\.name)), ["copied layout", "renamed"])
        XCTAssertEqual(reader.load(name: "copied layout")?.name, "copied layout")
        XCTAssertEqual(reader.load(name: "renamed")?.name, "renamed")
        XCTAssertEqual(reader.load(name: "copied layout")?.layout, layout)
        try reader.remove(name: "copied layout")
        XCTAssertNil(reader.load(name: "copied layout"))
        XCTAssertNotNil(reader.load(name: "renamed"))
    }

    func testInvalidLayoutNamesCannotReadWriteOrRemoveOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("layouts")
        let store = ProgramaLayoutStore(directoryURL: directory, startWatching: false)
        let valid = URL(fileURLWithPath: try store.save(name: "valid layout", layout: layout, force: false))
        let bytes = try Data(contentsOf: valid)
        let outside = root.appendingPathComponent("outside.json")
        try bytes.write(to: outside)
        for name in ["", ".", "..", "../outside", "nested/name", "valid layout\0suffix"] {
            XCTAssertThrowsError(try store.save(name: name, layout: layout, force: true), name) {
                guard case ProgramaLayoutStoreError.invalidName = $0 else { return XCTFail("Expected invalidName for \(name)") }
            }
            XCTAssertNil(store.load(name: name), name)
            XCTAssertThrowsError(try store.remove(name: name), name) {
                guard case ProgramaLayoutStoreError.invalidName = $0 else { return XCTFail("Expected invalidName for \(name)") }
            }
            XCTAssertEqual(try Data(contentsOf: valid), bytes)
            XCTAssertEqual(try Data(contentsOf: outside), bytes)
        }
        XCTAssertEqual(store.load(name: "valid layout")?.layout, layout, "Spaces are valid layout names")
    }
}

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
func makeTemporaryBrowserProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

final class SidebarSelectedWorkspaceColorTests: XCTestCase {
    func testLightModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .light).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 136.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testDarkModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .dark).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 145.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundAlwaysUsesWhiteWithRequestedOpacity() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }
}


final class WorkspaceRenameShortcutDefaultsTests: XCTestCase {
    func testRenameTabShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.label, "Rename Tab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.defaultsKey, "shortcut.renameTab")

        let shortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWindowShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.label, "Close Window")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.defaultsKey, "shortcut.closeWindow")

        let shortcut = KeyboardShortcutSettings.Action.closeWindow.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
    }

    func testRenameWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.label, "Rename Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey, "shortcut.renameWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRenameWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testCloseWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.label, "Close Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey, "shortcut.closeWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testNextPreviousWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.label, "Next Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.label, "Previous Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey, "shortcut.nextSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey, "shortcut.prevSidebarTab")

        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertEqual(nextShortcut.key, "]")
        XCTAssertTrue(nextShortcut.command)
        XCTAssertFalse(nextShortcut.shift)
        XCTAssertFalse(nextShortcut.option)
        XCTAssertTrue(nextShortcut.control)

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertEqual(prevShortcut.key, "[")
        XCTAssertTrue(prevShortcut.command)
        XCTAssertFalse(prevShortcut.shift)
        XCTAssertFalse(prevShortcut.option)
        XCTAssertTrue(prevShortcut.control)
    }

    func testNextPreviousWorkspaceShortcutsConvertToMenuShortcut() {
        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertNotNil(nextShortcut.keyEquivalent)
        XCTAssertEqual(nextShortcut.menuItemKeyEquivalent, "]")
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.control))

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertNotNil(prevShortcut.keyEquivalent)
        XCTAssertEqual(prevShortcut.menuItemKeyEquivalent, "[")
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.control))
    }

    func testToggleTerminalCopyModeShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.toggleTerminalCopyMode.label, "Toggle Terminal Copy Mode")
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleTerminalCopyMode.defaultsKey,
            "shortcut.toggleTerminalCopyMode"
        )

        let shortcut = KeyboardShortcutSettings.Action.toggleTerminalCopyMode.defaultShortcut
        XCTAssertEqual(shortcut.key, "m")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testMenuItemKeyEquivalentHandlesArrowAndTabKeys() {
        XCTAssertNotNil(StoredShortcut(key: "←", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "→", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↑", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↓", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertEqual(
            StoredShortcut(key: "\t", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent,
            "\t"
        )
    }

    func testShortcutDefaultsKeysRemainUnique() {
        let keys = KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testChordedShortcutDisplayDisablesMenuKeyEquivalent() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        XCTAssertEqual(shortcut.displayString, "⌃B D")
        XCTAssertNil(shortcut.keyEquivalent)
        XCTAssertNil(shortcut.menuItemKeyEquivalent)
    }

    func testNumberedChordDisplayUsesChordSuffix() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "7"
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.displayedShortcutString(for: shortcut),
            "⌃B 1…9"
        )
    }

    func testNumberedChordNormalizationTargetsSecondStroke() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "7"
        )

        let normalized = KeyboardShortcutSettings.Action.selectWorkspaceByNumber.normalizedRecordedShortcut(shortcut)
        XCTAssertEqual(normalized?.key, "b")
        XCTAssertEqual(normalized?.chordKey, "1")
    }

    func testStoredShortcutDecodesLegacySingleStrokePayload() throws {
        let data = """
        {"key":"d","command":true,"shift":false,"option":false,"control":false}
        """.data(using: .utf8)!

        let shortcut = try JSONDecoder().decode(StoredShortcut.self, from: data)

        XCTAssertEqual(shortcut.key, "d")
        XCTAssertFalse(shortcut.hasChord)
        XCTAssertNil(shortcut.chordKey)
    }

    func testEscapeCancelDetectionTreatsEscapeCharacterAsCancelEvenWithUnexpectedKeyCode() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to construct escape-like event")
            return
        }

        XCTAssertTrue(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertNil(ShortcutStroke.from(event: event, requireModifier: false))
    }

    func testEscapeCancelDetectionAllowsModifiedEscapeGeneratingShortcut() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 33
        ) else {
            XCTFail("Failed to construct modified escape-generating event")
            return
        }

        XCTAssertFalse(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertEqual(
            ShortcutStroke.from(event: event, requireModifier: false),
            ShortcutStroke(key: "[", command: true, shift: false, option: false, control: false)
        )
    }

    func testShortcutRecorderStopsRecordingWhenFirstStrokeConfirmationIsRejected() {
#if DEBUG
        let button = ShortcutRecorderNSButton(frame: .zero)
        button.transformRecordedShortcut = { _ in nil }
        button.debugSetPendingChordStart(
            ShortcutStroke(
                key: "x",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )

        button.performClick(nil)

        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }
}

final class KeyboardShortcutSettingsFileStoreTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testSettingsFileStoreParsesSingleStrokeChordAndNumberedChord() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "cmd+b",
                "newTab": ["ctrl+b", "c"],
                "selectWorkspaceByNumber": ["ctrl+b", "7"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .toggleSidebar),
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "1")
        )
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
    }

    func testUncommentedTemplatePreservesDefaultReturnShortcut() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json")
        var inShortcuts = false
        var shortcutsIndent: Int?
        let template = ProgramaSettingsFileStore.defaultTemplate().components(separatedBy: "\n").map { line in
            if line.contains("\"shortcuts\"") && line.contains("{") { inShortcuts = true }
            guard inShortcuts, let marker = line.range(of: "// ") else { return line }
            let uncommented = String(line[..<marker.lowerBound]) + String(line[marker.upperBound...])
            let indent = uncommented.prefix(while: { $0.isWhitespace }).count
            if shortcutsIndent == nil { shortcutsIndent = indent }
            if indent == shortcutsIndent && uncommented.trimmingCharacters(in: .whitespaces) == "}," {
                inShortcuts = false
            }
            return uncommented
        }.joined(separator: "\n")
        XCTAssertNotNil(shortcutsIndent, "The fixture must activate the generated shortcuts section before loading it")
        try writeSettingsFile(template, to: settingsFileURL)
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path, fallbackPath: nil, startWatching: false
        )
        XCTAssertEqual(store.override(for: .toggleSplitZoom), KeyboardShortcutSettings.Action.toggleSplitZoom.defaultShortcut,
                       "Uncommenting the supplied template must retain the default Return shortcut")
    }

    func testSettingsFileStoreRejectsModifierFreeFirstStroke() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "b",
                "newTab": ["b", "c"],
                "splitRight": ["ctrl+b", "d"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(store.override(for: .toggleSidebar))
        XCTAssertNil(store.override(for: .newTab))
        XCTAssertEqual(
            store.override(for: .splitRight),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "d")
        )
    }

    func testSettingsFileStoreUsesFallbackOnlyWhenPrimaryIsMissing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let fallbackStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertEqual(
            fallbackStore.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(fallbackStore.activeSourcePath, fallbackURL.path)

        try writeSettingsFile("{ not valid json", to: primaryURL)

        let invalidPrimaryStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertNil(invalidPrimaryStore.override(for: .showNotifications))
        XCTAssertEqual(invalidPrimaryStore.activeSourcePath, primaryURL.path)
    }

    func testShortcutSettingsFileOverridesPersistedShortcutValues() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false),
            for: .newTab
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertTrue(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
        XCTAssertNotNil(KeyboardShortcutSettings.settingsFileManagedSubtitle(for: .newTab))
    }

    @MainActor
    func testReloadConfigurationReloadsShortcutSettingsFile() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config")

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    func testManagedShortcutWritesDoNotOverwritePersistedValue() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let missingSettingsFileURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        let persistedShortcut = StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        let managedShortcut = StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")

        KeyboardShortcutSettings.setShortcut(persistedShortcut, for: .newTab)

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "t", command: true, shift: false, option: false, control: false),
            for: .newTab
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertFalse(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), persistedShortcut)
    }

    func testBootstrapCreatesCommentedTemplateWhenPrimaryAndFallbackAreMissing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL
            .appendingPathComponent(".config/cmux", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFileURL.path))
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
        XCTAssertNil(store.override(for: .newTab))

        let contents = try String(contentsOf: settingsFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(#""$schema": "https://raw.githubusercontent.com/darkroomengineering/programa/main/Resources/settings.schema.json""#))
        XCTAssertTrue(contents.contains(#""schemaVersion": 1,"#))
        XCTAssertTrue(contents.contains(#"//   "app" : {"#))
        XCTAssertTrue(contents.contains(#"//     "colors" : {"#))
        XCTAssertTrue(contents.contains(##"//       "Red" : "#C0392B""##))
        XCTAssertTrue(contents.contains(#"//   "shortcuts" : {"#))
    }

    func testBootstrapDoesNotCreatePrimaryWhenFallbackAlreadyExists() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/settings.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertEqual(store.activeSourcePath, fallbackURL.path)
    }

    func testSettingsFileURLForEditingUsesActiveFallbackWithoutCreatingPrimary() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/settings.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, fallbackURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
    }

    func testSettingsFileURLForEditingPrefersInvalidPrimaryForRepair() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/settings.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile("{ not valid json", to: primaryURL)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, primaryURL.path)
        XCTAssertEqual(store.activeSourcePath, primaryURL.path)
    }

    func testSettingsFileStoreParsesJSONCCommentsAndTrailingCommas() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/darkroomengineering/programa/main/Resources/settings.schema.json",
              "schemaVersion": 1,
              // tmux-like prefix
              "shortcuts": {
                "bindings": {
                  "newTab": [
                    "ctrl+b",
                    "c",
                  ],
                },
              },
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    func testFutureSchemaVersionStillParsesKnownFields() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "schemaVersion": 999,
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
    }

    func testInvalidAppEnumDoesNotPreventValidLaterSiblingSettings() throws {
        let defaults = UserDefaults.standard
        let backupsKey = "programa.settingsFile.backups.v1"
        let appearanceKey = AppearanceSettings.appearanceModeKey
        let placementKey = WorkspacePlacementSettings.placementKey
        let warningKey = QuitWarningSettings.warnBeforeQuitKey
        let previousAppearance = defaults.object(forKey: appearanceKey)
        let previousPlacement = defaults.object(forKey: placementKey)
        let previousWarning = defaults.object(forKey: warningKey)
        let previousBackups = defaults.data(forKey: backupsKey)
        defer {
            restoreDefaultsValue(previousAppearance, key: appearanceKey, defaults: defaults)
            restoreDefaultsValue(previousPlacement, key: placementKey, defaults: defaults)
            restoreDefaultsValue(previousWarning, key: warningKey, defaults: defaults)
            if let previousBackups {
                defaults.set(previousBackups, forKey: backupsKey)
            } else {
                defaults.removeObject(forKey: backupsKey)
            }
        }

        defaults.set(AppearanceMode.system.rawValue, forKey: appearanceKey)
        defaults.set(NewWorkspacePlacement.top.rawValue, forKey: placementKey)
        defaults.set(true, forKey: warningKey)
        defaults.removeObject(forKey: backupsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json")
        try writeSettingsFile(
            """
            {
              "app": {
                "appearance": "not-a-real-mode",
                "newWorkspacePlacement": "end",
                "warnBeforeQuit": false
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .end)
        XCTAssertFalse(QuitWarningSettings.isEnabled(defaults: defaults))
    }

    func testReloadWithInvalidEnumKeepsValidLaterSiblingManaged() throws {
        let defaults = UserDefaults.standard
        let backupsKey = "programa.settingsFile.backups.v1"
        let appearanceKey = AppearanceSettings.appearanceModeKey
        let warningKey = QuitWarningSettings.warnBeforeQuitKey
        let previousAppearance = defaults.object(forKey: appearanceKey)
        let previousWarning = defaults.object(forKey: warningKey)
        let previousBackups = defaults.data(forKey: backupsKey)
        defer {
            restoreDefaultsValue(previousAppearance, key: appearanceKey, defaults: defaults)
            restoreDefaultsValue(previousWarning, key: warningKey, defaults: defaults)
            if let previousBackups {
                defaults.set(previousBackups, forKey: backupsKey)
            } else {
                defaults.removeObject(forKey: backupsKey)
            }
        }

        defaults.set(AppearanceMode.system.rawValue, forKey: appearanceKey)
        defaults.set(false, forKey: warningKey)
        defaults.removeObject(forKey: backupsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json")
        try writeSettingsFile(
            """
            {
              "app": {
                "appearance": "dark",
                "warnBeforeQuit": false
              }
            }
            """,
            to: settingsFileURL
        )
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        try writeSettingsFile(
            """
            {
              "app": {
                "appearance": "not-a-real-mode",
                "warnBeforeQuit": true
              }
            }
            """,
            to: settingsFileURL
        )
        store.reload()

        XCTAssertTrue(
            QuitWarningSettings.isEnabled(defaults: defaults),
            "A malformed appearance value must not unmanage a valid warnBeforeQuit sibling during reload"
        )
    }

    func testSettingsFileRejectsInvalidCombinedAutomationPortInterval() throws {
        let defaults = UserDefaults.standard
        let backupsKey = "programa.settingsFile.backups.v1"
        let baseKey = ProgramaPortRangePolicy.baseDefaultsKey
        let rangeKey = ProgramaPortRangePolicy.rangeDefaultsKey
        let previousBase = defaults.object(forKey: baseKey)
        let previousRange = defaults.object(forKey: rangeKey)
        let previousBackups = defaults.data(forKey: backupsKey)
        defer {
            restoreDefaultsValue(previousBase, key: baseKey, defaults: defaults)
            restoreDefaultsValue(previousRange, key: rangeKey, defaults: defaults)
            if let previousBackups {
                defaults.set(previousBackups, forKey: backupsKey)
            } else {
                defaults.removeObject(forKey: backupsKey)
            }
        }

        defaults.set(12_000, forKey: baseKey)
        defaults.set(20, forKey: rangeKey)
        defaults.removeObject(forKey: backupsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json")
        try writeSettingsFile(
            """
            {
              "automation": {
                "portBase": 65530,
                "portRange": 10
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.integer(forKey: baseKey), 12_000)
        XCTAssertEqual(defaults.integer(forKey: rangeKey), 20)
        XCTAssertNil(defaults.data(forKey: backupsKey))
    }

    func testSettingsFileAppliesValidAutomationPortIntervalAtomically() throws {
        let defaults = UserDefaults.standard
        let backupsKey = "programa.settingsFile.backups.v1"
        let baseKey = ProgramaPortRangePolicy.baseDefaultsKey
        let rangeKey = ProgramaPortRangePolicy.rangeDefaultsKey
        let previousBase = defaults.object(forKey: baseKey)
        let previousRange = defaults.object(forKey: rangeKey)
        let previousBackups = defaults.data(forKey: backupsKey)
        defer {
            restoreDefaultsValue(previousBase, key: baseKey, defaults: defaults)
            restoreDefaultsValue(previousRange, key: rangeKey, defaults: defaults)
            if let previousBackups {
                defaults.set(previousBackups, forKey: backupsKey)
            } else {
                defaults.removeObject(forKey: backupsKey)
            }
        }

        defaults.set(12_000, forKey: baseKey)
        defaults.set(20, forKey: rangeKey)
        defaults.removeObject(forKey: backupsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json")
        try writeSettingsFile(
            """
            {
              "automation": {
                "portBase": 64000,
                "portRange": 100
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.integer(forKey: baseKey), 64_000)
        XCTAssertEqual(defaults.integer(forKey: rangeKey), 100)
        XCTAssertNotNil(defaults.data(forKey: backupsKey))
    }

    func testSettingsFileRejectsSingleAutomationPortKeyThatOverflowsWithDefaultCounterpart() throws {
        let defaults = UserDefaults.standard
        let backupsKey = "programa.settingsFile.backups.v1"
        let baseKey = ProgramaPortRangePolicy.baseDefaultsKey
        let rangeKey = ProgramaPortRangePolicy.rangeDefaultsKey
        let previousBase = defaults.object(forKey: baseKey)
        let previousRange = defaults.object(forKey: rangeKey)
        let previousBackups = defaults.data(forKey: backupsKey)
        defer {
            restoreDefaultsValue(previousBase, key: baseKey, defaults: defaults)
            restoreDefaultsValue(previousRange, key: rangeKey, defaults: defaults)
            if let previousBackups {
                defaults.set(previousBackups, forKey: backupsKey)
            } else {
                defaults.removeObject(forKey: backupsKey)
            }
        }

        defaults.set(12_000, forKey: baseKey)
        defaults.set(20, forKey: rangeKey)
        defaults.removeObject(forKey: backupsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json")
        try writeSettingsFile(
            """
            {
              "automation": {
                "portBase": 65530
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.integer(forKey: baseKey), 12_000)
        XCTAssertEqual(defaults.integer(forKey: rangeKey), 20)
        XCTAssertNil(defaults.data(forKey: backupsKey))
    }

    func testManagedUserDefaultSettingRestoresBackedUpValueWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspaceAutoReorderSettings.key
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.set(false, forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "reorderOnNotification": true
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, true)

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, false)
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    func testSettingsFileStoreAppliesWorkspaceColorDictionaryAndAllowsRemovingDefaults() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Blue": "#2244ff",
                  "Neon Mint": "#00f5d4"
                }
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let palette = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(palette.map(\.name), ["Blue", "Neon Mint"])
        XCTAssertEqual(palette.map(\.hex), ["#2244FF", "#00F5D4"])
    }

    func testManagedWorkspaceColorsRestoreLegacyPaletteWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Neon Mint": "#00F5D4"
                }
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults).map(\.name), ["Neon Mint"])

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let restored = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(restored.first(where: { $0.name == "Blue" })?.hex, "#010203")
        XCTAssertEqual(restored.first(where: { $0.name == "Custom 1" })?.hex, "#778899")
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    @MainActor
    func testReloadConfigurationReloadsManagedAppSettingsFromSettingsFile() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspacePlacementSettings.placementKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspacePlacementSettings.current(), .top)

        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "end"
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config_app_setting")

        XCTAssertEqual(WorkspacePlacementSettings.current(), .end)
    }

    @MainActor
    func testManagedWorkspacePlacementChangesDefaultInsertionBehavior() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspacePlacementSettings.placementKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let manager = TabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace(placementOverride: .end)
        let third = manager.addWorkspace(placementOverride: .end)
        manager.selectWorkspace(first)

        let inserted = manager.addWorkspace()

        XCTAssertEqual(manager.tabs.map(\.id), [inserted.id, first.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}


final class TerminalThemeSettingsTests: XCTestCase {
    private let settingsFileBackupsDefaultsKey = "programa.settingsFile.backups.v1"

    func testManagedOverrideRoundTripsAndPreservesUnrelatedConfig() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        try "font-size = 15\n".write(to: configURL, atomically: true, encoding: .utf8)
        let store = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: configURL,
            configSearchURLs: [configURL]
        )

        let firstMutation = try store.set(light: "Cloud Light", dark: "Midnight Dark")
        XCTAssertTrue(firstMutation.didChange)
        XCTAssertEqual(firstMutation.configURL, configURL)

        let selection = store.currentSelection()
        XCTAssertEqual(selection.rawValue, "light:Cloud Light,dark:Midnight Dark")
        XCTAssertEqual(selection.light, "Cloud Light")
        XCTAssertEqual(selection.dark, "Midnight Dark")
        XCTAssertEqual(selection.sourcePath, configURL.path)

        let managedContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(managedContents.contains("font-size = 15"))
        XCTAssertTrue(managedContents.contains("# programa themes start"))
        XCTAssertTrue(managedContents.contains("theme = light:Cloud Light,dark:Midnight Dark"))

        let repeatedMutation = try store.set(light: "Cloud Light", dark: "Midnight Dark")
        XCTAssertFalse(repeatedMutation.didChange)

        let clearMutation = try store.clear()
        XCTAssertTrue(clearMutation.didChange)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "font-size = 15\n")
        XCTAssertNil(store.managedRawThemeValue())
    }

    func testSettingsFileManagesThemeAndRestoresPriorOverrideWhenRemoved() throws {
        let defaults = UserDefaults.standard
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let configURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        let themeStore = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: configURL,
            configSearchURLs: [configURL]
        )
        _ = try themeStore.set(light: "Original Light", dark: "Original Dark")
        try writeSettingsFile(
            """
            {
              "app": {
                "terminalTheme": {
                  "light": "Managed Light",
                  "dark": "Managed Dark"
                }
              }
            }
            """,
            to: settingsURL
        )

        var reloadRequestCount = 0
        let settingsStore = ProgramaSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            fileManager: .default,
            notificationCenter: .default,
            terminalThemeStore: themeStore,
            terminalThemeReloadHandler: { reloadRequestCount += 1 },
            startWatching: false
        )

        XCTAssertTrue(settingsStore.isTerminalThemeManagedByFile())
        XCTAssertEqual(themeStore.currentSelection().light, "Managed Light")
        XCTAssertEqual(themeStore.currentSelection().dark, "Managed Dark")
        XCTAssertEqual(reloadRequestCount, 1)

        try writeSettingsFile("{ \"app\": {} }", to: settingsURL)
        settingsStore.reload()

        XCTAssertFalse(settingsStore.isTerminalThemeManagedByFile())
        XCTAssertEqual(themeStore.currentSelection().light, "Original Light")
        XCTAssertEqual(themeStore.currentSelection().dark, "Original Dark")
        XCTAssertEqual(reloadRequestCount, 2)
    }

    func testSettingsFileMapsExternalBrowserToManagedDefaults() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.string(forKey: BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey)
        defer {
            restoreDefaultsValue(
                previousValue,
                key: BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey,
                defaults: defaults
            )
        }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        let configURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        let themeStore = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: configURL,
            configSearchURLs: [configURL]
        )
        try writeSettingsFile(
            """
            {
              "browser": {
                "externalBrowser": "com.apple.Safari"
              }
            }
            """,
            to: settingsURL
        )

        _ = ProgramaSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            fileManager: .default,
            notificationCenter: .default,
            terminalThemeStore: themeStore,
            terminalThemeReloadHandler: {},
            startWatching: false
        )

        XCTAssertEqual(
            defaults.string(forKey: BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey),
            "com.apple.Safari"
        )
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testAppearanceOverridesRoundTripAllFourDirectives() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        let store = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: configURL,
            configSearchURLs: [configURL]
        )

        let overrides = TerminalAppearanceOverrides(
            themeLight: "Cloud Light",
            themeDark: "Midnight Dark",
            backgroundOpacity: 0.85,
            backgroundBlur: true,
            fontFamily: "JetBrains Mono",
            fontSize: 13
        )
        let mutation = try store.set(overrides)
        XCTAssertTrue(mutation.didChange)

        let readBack = store.currentAppearance()
        XCTAssertEqual(readBack.themeLight, "Cloud Light")
        XCTAssertEqual(readBack.themeDark, "Midnight Dark")
        XCTAssertEqual(readBack.backgroundOpacity, 0.85)
        XCTAssertEqual(readBack.backgroundBlur, true)
        XCTAssertEqual(readBack.fontFamily, "JetBrains Mono")
        XCTAssertEqual(readBack.fontSize, 13)

        let managedContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(managedContents.contains("theme = light:Cloud Light,dark:Midnight Dark"))
        XCTAssertTrue(managedContents.contains("background-opacity = 0.85"))
        XCTAssertTrue(managedContents.contains("background-blur = true"))
        XCTAssertTrue(managedContents.contains("font-family = JetBrains Mono"))
        XCTAssertTrue(managedContents.contains("font-size = 13.0"))
    }

    func testSurgicalSingleKeyWritePreservesOtherDirectives() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        let store = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: configURL,
            configSearchURLs: [configURL]
        )

        _ = try store.set(TerminalAppearanceOverrides(themeLight: "Cloud Light", themeDark: "Midnight Dark"))
        _ = try store.set(rawAppearanceValue: "0.7", forKey: "background-opacity")

        let afterOpacity = store.currentAppearance()
        XCTAssertEqual(afterOpacity.themeLight, "Cloud Light")
        XCTAssertEqual(afterOpacity.themeDark, "Midnight Dark")
        XCTAssertEqual(afterOpacity.backgroundOpacity, 0.7)

        _ = try store.set(rawAppearanceValues: ["font-family": "Menlo", "font-size": "14"])

        let afterFont = store.currentAppearance()
        XCTAssertEqual(afterFont.themeLight, "Cloud Light", "setting font must not clobber theme")
        XCTAssertEqual(afterFont.backgroundOpacity, 0.7, "setting font must not clobber opacity")
        XCTAssertEqual(afterFont.fontFamily, "Menlo")
        XCTAssertEqual(afterFont.fontSize, 14)

        _ = try store.set(rawAppearanceValue: "", forKey: "background-opacity")
        let afterClearingOpacity = store.currentAppearance()
        XCTAssertNil(afterClearingOpacity.backgroundOpacity, "clearing one key must not clear the block")
        XCTAssertEqual(afterClearingOpacity.themeLight, "Cloud Light")
        XCTAssertEqual(afterClearingOpacity.fontFamily, "Menlo")
    }

    func testAllNilOverridesClearsTheManagedBlock() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        try "font-size = 15\n".write(to: configURL, atomically: true, encoding: .utf8)
        let store = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: configURL,
            configSearchURLs: [configURL]
        )

        _ = try store.set(TerminalAppearanceOverrides(backgroundOpacity: 0.5, backgroundBlur: true))
        XCTAssertNotNil(store.managedRawAppearance().backgroundOpacity)

        let clearMutation = try store.set(TerminalAppearanceOverrides())
        XCTAssertTrue(clearMutation.didChange)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "font-size = 15\n")
        XCTAssertEqual(store.managedRawAppearance(), TerminalAppearanceOverrides())
    }

    func testPartialWriteBasedOnManagedBlockDoesNotCaptureValuesFromAnUnmanagedConfigFile() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        // A separate, user-owned config file earlier in the search chain — never written to by
        // Programa — with its own theme and font that Programa doesn't manage.
        let userConfigURL = directoryURL.appendingPathComponent("config", isDirectory: false)
        try """
        theme = light:UserTheme,dark:UserThemeDark
        font-family = User Mono
        """.write(to: userConfigURL, atomically: true, encoding: .utf8)

        let managedConfigURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        let store = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: managedConfigURL,
            configSearchURLs: [userConfigURL, managedConfigURL]
        )

        // The effective, resolved state includes the user's own config...
        let effective = store.currentAppearance()
        XCTAssertEqual(effective.themeLight, "UserTheme")
        XCTAssertEqual(effective.fontFamily, "User Mono")
        // ...but nothing is Programa-managed yet.
        XCTAssertEqual(store.managedRawAppearance(), TerminalAppearanceOverrides())

        // Simulate the caller contract used by Settings/CLI: build the write from
        // managedRawAppearance() (not currentAppearance()), touching only the one field.
        var overrides = store.managedRawAppearance()
        overrides.backgroundOpacity = 0.6
        _ = try store.set(overrides)

        let managedContents = try String(contentsOf: managedConfigURL, encoding: .utf8)
        XCTAssertTrue(managedContents.contains("background-opacity = 0.6"))
        XCTAssertFalse(managedContents.contains("theme ="), "the user's theme must not be captured into the managed block")
        XCTAssertFalse(managedContents.contains("font-family ="), "the user's font must not be captured into the managed block")

        // The user's own config is untouched and still resolves as before.
        let effectiveAfter = store.currentAppearance()
        XCTAssertEqual(effectiveAfter.themeLight, "UserTheme")
        XCTAssertEqual(effectiveAfter.fontFamily, "User Mono")
        XCTAssertEqual(effectiveAfter.backgroundOpacity, 0.6)
        XCTAssertEqual(try String(contentsOf: userConfigURL, encoding: .utf8).contains("User Mono"), true)
    }

    func testExplicitBlurFalseIsDistinctFromInherit() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        // A raw Ghostty config earlier in the chain turns blur on.
        let userConfigURL = directoryURL.appendingPathComponent("config", isDirectory: false)
        try "background-blur = true\n".write(to: userConfigURL, atomically: true, encoding: .utf8)

        let managedConfigURL = directoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        let store = TerminalThemeStore(
            fileManager: .default,
            managedConfigURL: managedConfigURL,
            configSearchURLs: [userConfigURL, managedConfigURL]
        )

        XCTAssertEqual(store.currentAppearance().backgroundBlur, true)

        // Explicitly turning it off via Programa must write a real `false`, not omit the key —
        // an omitted key would fall through to the user's `background-blur = true` above.
        _ = try store.set(TerminalAppearanceOverrides(backgroundBlur: false))

        let managedContents = try String(contentsOf: managedConfigURL, encoding: .utf8)
        XCTAssertTrue(managedContents.contains("background-blur = false"))
        XCTAssertEqual(store.managedRawAppearance().backgroundBlur, false)
        XCTAssertEqual(store.currentAppearance().backgroundBlur, false)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}


final class WorkspaceShortcutMapperTests: XCTestCase {
    func testCommandNineMapsToLastWorkspaceIndex() {
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forDigit: 9, workspaceCount: 1), 0)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forDigit: 9, workspaceCount: 4), 3)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forDigit: 9, workspaceCount: 12), 11)
    }

    func testCommandDigitBadgesUseNineForLastWorkspaceWhenNeeded() {
        XCTAssertEqual(WorkspaceShortcutMapper.digitForWorkspace(at: 0, workspaceCount: 12), 1)
        XCTAssertEqual(WorkspaceShortcutMapper.digitForWorkspace(at: 7, workspaceCount: 12), 8)
        XCTAssertEqual(WorkspaceShortcutMapper.digitForWorkspace(at: 11, workspaceCount: 12), 9)
        XCTAssertNil(WorkspaceShortcutMapper.digitForWorkspace(at: 8, workspaceCount: 12))
    }
}
@MainActor
final class WorkspaceCustomDescriptionTests: XCTestCase {
    func testSetCustomDescriptionPreservesMeaningfulLeadingAndTrailingWhitespace() {
        let workspace = Workspace()
        let description = "  line one\n\nline two\n\n"

        workspace.setCustomDescription(description)

        XCTAssertEqual(workspace.customDescription, description)
        XCTAssertTrue(workspace.hasCustomDescription)
    }

    func testSetCustomDescriptionClearsWhitespaceOnlyDescriptions() {
        let workspace = Workspace()

        workspace.setCustomDescription(" \n\t \n")

        XCTAssertNil(workspace.customDescription)
        XCTAssertFalse(workspace.hasCustomDescription)
    }
}
final class WorkspacePlacementSettingsTests: XCTestCase {
    func testCurrentPlacementDefaultsToAfterCurrentWhenUnset() {
        let suiteName = "WorkspacePlacementSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testCurrentPlacementReadsStoredValidValueAndFallsBackForInvalid() {
        let suiteName = "WorkspacePlacementSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NewWorkspacePlacement.top.rawValue, forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .top)

        defaults.set("nope", forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testInsertionIndexTopInsertsBeforeUnpinned() {
        let index = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 4,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 7
        )
        XCTAssertEqual(index, 2)
    }

    func testInsertionIndexAfterCurrentHandlesPinnedAndUnpinnedSelection() {
        let afterUnpinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 3,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterUnpinned, 4)

        let afterPinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 0,
            selectedIsPinned: true,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterPinned, 2)
    }

    func testInsertionIndexEndAndNoSelectionAppend() {
        let endIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: 1,
            selectedIsPinned: false,
            pinnedCount: 1,
            totalCount: 5
        )
        XCTAssertEqual(endIndex, 5)

        let noSelectionIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            selectedIsPinned: false,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(noSelectionIndex, 5)
    }
}


@MainActor
final class WorkspaceCreationPlacementTests: XCTestCase {
    private final class SnapshotMutatingTabManager: TabManager {
        var afterCaptureWorkspaceCreationSnapshot: (() -> Void)?
        var beforeCreateWorkspace: (() -> Void)?

        override func didCaptureWorkspaceCreationSnapshot() {
            afterCaptureWorkspaceCreationSnapshot?()
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: ProgramaSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            beforeCreateWorkspace?()
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
        }
    }

    func testAddWorkspaceDefaultPlacementMatchesCurrentSetting() {
        let currentPlacement = WorkspacePlacementSettings.current()

        let defaultManager = makeManagerWithThreeWorkspaces()
        let defaultBaselineOrder = defaultManager.tabs.map(\.id)
        let defaultInserted = defaultManager.addWorkspace()
        guard let defaultInsertedIndex = defaultManager.tabs.firstIndex(where: { $0.id == defaultInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(defaultManager.tabs.map(\.id).filter { $0 != defaultInserted.id }, defaultBaselineOrder)

        let explicitManager = makeManagerWithThreeWorkspaces()
        let explicitBaselineOrder = explicitManager.tabs.map(\.id)
        let explicitInserted = explicitManager.addWorkspace(placementOverride: currentPlacement)
        guard let explicitInsertedIndex = explicitManager.tabs.firstIndex(where: { $0.id == explicitInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(explicitManager.tabs.map(\.id).filter { $0 != explicitInserted.id }, explicitBaselineOrder)
        XCTAssertEqual(defaultInsertedIndex, explicitInsertedIndex)
    }

    func testAddWorkspaceEndOverrideAlwaysAppends() {
        let manager = makeManagerWithThreeWorkspaces()
        let baselineCount = manager.tabs.count
        guard baselineCount >= 3 else {
            XCTFail("Expected at least three workspaces for placement regression test")
            return
        }

        let inserted = manager.addWorkspace(placementOverride: .end)
        guard let insertedIndex = manager.tabs.firstIndex(where: { $0.id == inserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }

        XCTAssertEqual(insertedIndex, baselineCount)
    }

    func testAddWorkspaceAfterCurrentOverrideAppendsAfterLastSelectedWorkspace() {
        let manager = TabManager()
        guard !manager.tabs.isEmpty else {
            XCTFail("Expected TabManager to initialise with at least one workspace")
            return
        }
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        let fourth = manager.addWorkspace()
        let baselineOrder = manager.tabs.map(\.id)

        manager.selectWorkspace(fourth)
        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.last?.id, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesPrecreationSnapshotWhenSelectionMutatesDuringBootstrap() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let baselineOrder = manager.tabs.map(\.id)
        manager.beforeCreateWorkspace = {
            manager.selectWorkspace(first)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentDoesNotReinsertClosedWorkspaceCapturedInSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(second)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == second.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesSelectedWorkspaceClosingAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(third)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == third.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesMidCreationClose() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let closingWorkspace = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let closingWorkspaceId = closingWorkspace.id
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, closingWorkspaceId, third.id])

        manager.afterCaptureWorkspaceCreationSnapshot = {
            guard let liveWorkspace = manager.tabs.first(where: { $0.id == closingWorkspaceId }) else {
                XCTFail("Expected captured workspace to still be present when closing after snapshot")
                return
            }
            manager.closeWorkspace(liveWorkspace)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == closingWorkspaceId }))
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesSnapshotPinnedStateWhenPinningMutatesAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(first)
        let baselineOrder = manager.tabs.map(\.id)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.setPinned(first, pinned: false)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, inserted.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentFollowsLiveReorderUsingSnapshotTabValues() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(second)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            XCTAssertTrue(
                manager.reorderWorkspace(tabId: third.id, toIndex: 0),
                "Expected to reorder live workspaces after the snapshot is captured"
            )
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(
            manager.tabs.map(\.id).filter { $0 != inserted.id },
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    private func makeManagerWithThreeWorkspaces() -> TabManager {
        let manager = TabManager()
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        if let first = manager.tabs.first {
            manager.selectWorkspace(first)
        }
        return manager
    }
}

@MainActor
final class WorkspaceCreationConfigSanitizationTests: XCTestCase {
    /// `makeWorkspaceForCreation` is the real seam `addWorkspace()` calls to construct the new
    /// workspace (TabManager.swift `addWorkspace()` -> `makeWorkspaceForCreation`); capturing its
    /// `configTemplate` argument lets us inspect exactly what addWorkspace() hands to workspace
    /// creation without needing to re-derive it from post-creation state.
    private final class ConfigTemplateCapturingTabManager: TabManager {
        var capturedConfigTemplate: ProgramaSurfaceConfigTemplate?

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: ProgramaSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            capturedConfigTemplate = configTemplate
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
        }
    }

    func testAddWorkspacePassesSanitizedInheritedConfigTemplate() {
        let manager = ConfigTemplateCapturingTabManager()

        // TabManager's own init already calls addWorkspace() once, so `selectedWorkspace` here is
        // the real source workspace the second addWorkspace() call below will inherit from — the
        // same source addWorkspace() consults via
        // `cachedInheritedTerminalFontPointsForNewWorkspace(workspace:)`
        // (TabManager.swift, reads `Workspace.lastRememberedTerminalFontPointsForConfigInheritance()`).
        guard let sourceWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected TabManager init to select an initial workspace")
            return
        }

        // Simulate an inherited terminal font size on the real seam addWorkspace() reads.
        sourceWorkspace.lastTerminalConfigInheritanceFontPoints = 19

        // The source workspace already has a real, non-nil `currentDirectory` (defaults to the
        // user's home directory) purely from ordinary initialization -- i.e. it is already
        // "dirty" with cwd state a naive implementation could leak into the new workspace's
        // config template. No command/env analog exists at the Workspace level; the seam under
        // test never reads live TerminalPanel/surface state for new-workspace creation (see the
        // comment on `cachedInheritedTerminalFontPointsForNewWorkspace`), so there is nothing to
        // dirty there -- that absence is itself the sanitization guarantee.
        XCTAssertFalse(sourceWorkspace.currentDirectory.isEmpty)

        _ = manager.addWorkspace()

        guard let capturedConfig = manager.capturedConfigTemplate else {
            XCTFail("Expected captured config template for new workspace")
            return
        }

        XCTAssertEqual(capturedConfig.fontSize, 19, accuracy: 0.001)
        XCTAssertNil(capturedConfig.workingDirectory)
        XCTAssertNil(capturedConfig.command)
        XCTAssertTrue(capturedConfig.environmentVariables.isEmpty)
    }
}


final class WorkspaceTabColorSettingsTests: XCTestCase {
    func testNormalizedHexAcceptsAndNormalizesValidInput() {
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("#abc123"), "#ABC123")
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("  aBcDeF "), "#ABCDEF")
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#1234"))
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#GG1234"))
    }

    func testBuiltInPaletteMatchesOriginalPRPalette() {
        let palette = WorkspaceTabColorSettings.defaultPalette
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette.first?.name, "Red")
        XCTAssertEqual(palette.first?.hex, "#C0392B")
        XCTAssertEqual(palette.last?.name, "Charcoal")
        XCTAssertFalse(palette.contains(where: { $0.name == "Gold" }))
    }

    func testPaletteFallsBackToBuiltInDefaultsWhenUnset() {
        let suiteName = "WorkspaceTabColorSettingsTests.BuiltInPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults), WorkspaceTabColorSettings.defaultPalette)
    }

    func testSetColorRoundTripFallsBackWhenResetToBase() {
        let suiteName = "WorkspaceTabColorSettingsTests.SetColor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            first.hex
        )

        WorkspaceTabColorSettings.setColor(named: first.name, hex: "#00aa33", defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            "#00AA33"
        )
        XCTAssertNotNil(defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey))

        WorkspaceTabColorSettings.setColor(named: first.name, hex: first.hex, defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            first.hex
        )
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.paletteKey))
    }

    func testRememberedFolderColorCanonicalizesAndClearsDirectory() {
        let suiteName = "WorkspaceTabColorSettingsTests.FolderColor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = "/tmp/programa-folder-color-\(UUID().uuidString)"

        WorkspaceTabColorSettings.rememberColor(
            " #abc123 ",
            forDirectory: directory + "/./",
            defaults: defaults
        )

        XCTAssertEqual(
            WorkspaceTabColorSettings.rememberedColor(
                forDirectory: directory,
                defaults: defaults
            ),
            "#ABC123"
        )
        WorkspaceTabColorSettings.rememberColor(nil, forDirectory: directory, defaults: defaults)
        XCTAssertNil(
            WorkspaceTabColorSettings.rememberedColor(
                forDirectory: directory,
                defaults: defaults
            )
        )
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.folderColorsKey))
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.folderColorOrderKey))
    }

    func testRememberedFolderColorsStayWithinBound() {
        let suiteName = "WorkspaceTabColorSettingsTests.FolderColorBound.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 0...WorkspaceTabColorSettings.maxRememberedFolderColors {
            WorkspaceTabColorSettings.rememberColor(
                "#123456",
                forDirectory: "/tmp/programa-folder-color-\(index)",
                defaults: defaults
            )
        }

        let stored = defaults.dictionary(forKey: WorkspaceTabColorSettings.folderColorsKey)
        XCTAssertEqual(stored?.count, WorkspaceTabColorSettings.maxRememberedFolderColors)
        XCTAssertNil(
            WorkspaceTabColorSettings.rememberedColor(
                forDirectory: "/tmp/programa-folder-color-0",
                defaults: defaults
            )
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.rememberedColor(
                forDirectory: "/tmp/programa-folder-color-\(WorkspaceTabColorSettings.maxRememberedFolderColors)",
                defaults: defaults
            ),
            "#123456"
        )
    }

    func testRememberedFolderColorsIgnoreMalformedEntriesIndependently() {
        let suiteName = "WorkspaceTabColorSettingsTests.MalformedFolderColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let validDirectory = "/tmp/programa-valid-folder-color"
        defaults.set(
            [
                validDirectory: "#123456",
                "/tmp/programa-invalid-folder-color": 42,
            ] as [String: Any],
            forKey: WorkspaceTabColorSettings.folderColorsKey
        )

        XCTAssertEqual(
            WorkspaceTabColorSettings.rememberedColor(
                forDirectory: validDirectory,
                defaults: defaults
            ),
            "#123456"
        )
    }

    @MainActor
    func testNewWorkspaceUsesColorRememberedForFolder() throws {
        let defaults = UserDefaults.standard
        let previousColors = defaults.dictionary(forKey: WorkspaceTabColorSettings.folderColorsKey)
        let previousOrder = defaults.stringArray(forKey: WorkspaceTabColorSettings.folderColorOrderKey)
        defer {
            WorkspaceTabColorSettings.resetRememberedFolderColors(defaults: defaults)
            if let previousColors {
                defaults.set(previousColors, forKey: WorkspaceTabColorSettings.folderColorsKey)
            }
            if let previousOrder {
                defaults.set(previousOrder, forKey: WorkspaceTabColorSettings.folderColorOrderKey)
            }
        }
        WorkspaceTabColorSettings.resetRememberedFolderColors(defaults: defaults)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-folder-color-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let manager = TabManager(initialWorkingDirectory: directoryURL.path)
        let firstWorkspace = try XCTUnwrap(manager.tabs.first)
        manager.setTabColor(tabId: firstWorkspace.id, color: "#AABBCC")
        let nextWorkspace = manager.addWorkspace(workingDirectory: directoryURL.path + "/./")

        XCTAssertEqual(nextWorkspace.customColor, "#AABBCC")
    }

    @MainActor
    func testNewWorkspaceCanSkipColorRememberedForFolder() throws {
        let defaults = UserDefaults.standard
        let previousColors = defaults.dictionary(forKey: WorkspaceTabColorSettings.folderColorsKey)
        let previousOrder = defaults.stringArray(forKey: WorkspaceTabColorSettings.folderColorOrderKey)
        defer {
            WorkspaceTabColorSettings.resetRememberedFolderColors(defaults: defaults)
            if let previousColors {
                defaults.set(previousColors, forKey: WorkspaceTabColorSettings.folderColorsKey)
            }
            if let previousOrder {
                defaults.set(previousOrder, forKey: WorkspaceTabColorSettings.folderColorOrderKey)
            }
        }
        WorkspaceTabColorSettings.resetRememberedFolderColors(defaults: defaults)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-folder-color-opt-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let manager = TabManager(initialWorkingDirectory: directoryURL.path)
        let firstWorkspace = try XCTUnwrap(manager.tabs.first)
        manager.setTabColor(tabId: firstWorkspace.id, color: "#AABBCC")
        let nextWorkspace = manager.addWorkspace(
            workingDirectory: directoryURL.path,
            applyRememberedFolderColor: false
        )

        XCTAssertNil(nextWorkspace.customColor)
    }

    func testAddCustomColorCreatesNamedEntriesAndDeduplicatesByHex() {
        let suiteName = "WorkspaceTabColorSettingsTests.NamedCustomColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor(" #00aa33 ", defaults: defaults),
            "#00AA33"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#112233", defaults: defaults),
            "#112233"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#00AA33", defaults: defaults),
            "#00AA33"
        )
        XCTAssertNil(WorkspaceTabColorSettings.addCustomColor("nope", defaults: defaults))

        let customEntries = WorkspaceTabColorSettings.customPaletteEntries(defaults: defaults)
        XCTAssertEqual(customEntries.map(\.name), ["Custom 1", "Custom 2"])
        XCTAssertEqual(customEntries.map(\.hex), ["#00AA33", "#112233"])
    }

    func testPaletteDictionaryCanRemoveBuiltInEntriesAndAddNamedOnes() {
        let suiteName = "WorkspaceTabColorSettingsTests.DictionaryPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var palette = Dictionary(uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) })
        palette.removeValue(forKey: "Red")
        palette["Neon Mint"] = "#00F5D4"
        WorkspaceTabColorSettings.persistPaletteMap(palette, defaults: defaults)

        let resolved = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertFalse(resolved.contains(where: { $0.name == "Red" }))
        XCTAssertEqual(resolved.first?.name, "Crimson")
        XCTAssertEqual(resolved.last?.name, "Neon Mint")
        XCTAssertEqual(resolved.last?.hex, "#00F5D4")
    }

    func testLegacyKeysStillResolveIntoEffectivePalette() {
        let suiteName = "WorkspaceTabColorSettingsTests.LegacyKeys.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")

        let resolved = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(
            resolved.first(where: { $0.name == "Blue" })?.hex,
            "#010203"
        )
        XCTAssertEqual(
            resolved.first(where: { $0.name == "Custom 1" })?.hex,
            "#778899"
        )
    }

    func testResetClearsNewAndLegacyStorage() {
        let suiteName = "WorkspaceTabColorSettingsTests.Reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WorkspaceTabColorSettings.persistPaletteMap(["Neon Mint": "#00F5D4"], defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")

        WorkspaceTabColorSettings.reset(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.paletteKey))
        XCTAssertNil(defaults.object(forKey: "workspaceTabColor.defaultOverrides"))
        XCTAssertNil(defaults.object(forKey: "workspaceTabColor.customColors"))
        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults), WorkspaceTabColorSettings.defaultPalette)
    }

    func testResetRememberedFolderColorsLeavesPaletteUntouched() {
        let suiteName = "WorkspaceTabColorSettingsTests.ResetFolderColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspaceTabColorSettings.persistPaletteMap(["Neon Mint": "#00F5D4"], defaults: defaults)
        WorkspaceTabColorSettings.rememberColor(
            "#112233",
            forDirectory: "/tmp/programa-folder-color",
            defaults: defaults
        )

        WorkspaceTabColorSettings.resetRememberedFolderColors(defaults: defaults)

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults).map(\.name), ["Neon Mint"])
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.folderColorsKey))
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.folderColorOrderKey))
    }

    func testDisplayColorLightModeKeepsOriginalHex() {
        let originalHex = "#1A5276"
        let rendered = WorkspaceTabColorSettings.displayNSColor(
            hex: originalHex,
            colorScheme: .light
        )

        XCTAssertEqual(rendered?.hexString(), originalHex)
    }

    func testDisplayColorDarkModeBrightensColor() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }

    func testDisplayColorDarkModeKeepsGrayscaleNeutral() {
        let originalHex = "#808080"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ),
              let renderedSRGB = rendered.usingColorSpace(.sRGB) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertGreaterThan(rendered.luminance, base.luminance)
        XCTAssertLessThan(abs(renderedSRGB.redComponent - renderedSRGB.greenComponent), 0.003)
        XCTAssertLessThan(abs(renderedSRGB.greenComponent - renderedSRGB.blueComponent), 0.003)
    }

    func testDisplayColorForceBrightensInLightMode() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .light,
                  forceBright: true
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }
}


final class WorkspaceAutoReorderSettingsTests: XCTestCase {
    func testDefaultIsEnabled() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testDisabledWhenSetToFalse() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertFalse(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testEnabledWhenSetToTrue() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }
}


final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testRelativeWorkspaceMovesUseIndicesAfterRemovingTheMovingWorkspace() {
        for (moving, anchor, before, expected) in [
            (0, 2, true, [1, 0, 2]), (0, 1, false, [1, 0, 2]),
            (2, 1, true, [0, 2, 1]), (2, 0, false, [0, 2, 1]),
            (1, 1, true, [0, 1, 2]), (1, 1, false, [0, 1, 2])
        ] {
            let manager = TabManager()
            _ = manager.addWorkspace()
            _ = manager.addWorkspace()
            let ids = manager.tabs.map(\.id)
            let selected = manager.selectedTabId
            XCTAssertTrue(manager.reorderWorkspace(tabId: ids[moving], before: before ? ids[anchor] : nil, after: before ? nil : ids[anchor]))
            XCTAssertEqual(manager.tabs.map(\.id), expected.map { ids[$0] })
            XCTAssertEqual(manager.selectedTabId, selected)
        }
    }

    @MainActor
    func testRelativeWorkspaceMovesRespectPinnedBoundary() {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let first = manager.addWorkspace()
        let second = manager.addWorkspace()
        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, before: pinned.id))
        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, second.id, first.id])
        XCTAssertTrue(manager.reorderWorkspace(tabId: pinned.id, after: first.id))
        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, second.id, first.id])
    }
    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }

    @MainActor
    func testReorderWorkspaceKeepsUnpinnedWorkspaceBelowPinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: unpinned.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [firstPinned.id, secondPinned.id, unpinned.id])
    }

    @MainActor
    func testReorderWorkspaceKeepsPinnedWorkspaceInsidePinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: firstPinned.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [secondPinned.id, firstPinned.id, unpinned.id])
    }
}


@MainActor
final class WorkspaceNotificationReorderTests: XCTestCase {
    func testNotificationAutoReorderDoesNotMovePinnedWorkspace() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let defaults = UserDefaults.standard
        let originalAutoReorderSetting = defaults.object(forKey: WorkspaceAutoReorderSettings.key)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        AppFocusState.overrideIsFocused = false

        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalAutoReorderSetting {
                defaults.set(originalAutoReorderSetting, forKey: WorkspaceAutoReorderSettings.key)
            } else {
                defaults.removeObject(forKey: WorkspaceAutoReorderSettings.key)
            }
        }

        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()
        let expectedOrder = [firstPinned.id, secondPinned.id, unpinned.id]

        notificationStore.addNotification(
            tabId: secondPinned.id,
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "Pinned workspaces should stay put"
        )

        XCTAssertEqual(manager.tabs.map(\.id), expectedOrder)
    }
}


@MainActor
final class WorkspaceTeardownTests: XCTestCase {
    func testTeardownAllPanelsClearsPanelMetadataCaches() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        workspace.setPanelCustomTitle(panelId: initialPanelId, title: "Initial custom title")
        workspace.setPanelPinned(panelId: initialPanelId, pinned: true)

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.setPanelCustomTitle(panelId: splitPanel.id, title: "Split custom title")
        workspace.setPanelPinned(panelId: splitPanel.id, pinned: true)
        workspace.markPanelUnread(initialPanelId)

        XCTAssertFalse(workspace.panels.isEmpty)
        XCTAssertFalse(workspace.panelTitles.isEmpty)
        XCTAssertFalse(workspace.panelCustomTitles.isEmpty)
        XCTAssertFalse(workspace.pinnedPanelIds.isEmpty)
        XCTAssertFalse(workspace.manualUnreadPanelIds.isEmpty)

        workspace.teardownAllPanels()

        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.panelTitles.isEmpty)
        XCTAssertTrue(workspace.panelCustomTitles.isEmpty)
        XCTAssertTrue(workspace.pinnedPanelIds.isEmpty)
        XCTAssertTrue(workspace.manualUnreadPanelIds.isEmpty)
    }
}


@MainActor
final class WorkspaceSplitWorkingDirectoryTests: XCTestCase {
    private func waitForCondition(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        // Scaled by `ciScale` (TabManagerUnitTests.swift), matching the copy of this
        // helper in that file. This one polls the main run loop for a real window to
        // settle, so a flat 2s is comfortable locally and thin on a loaded CI runner.
        let deadline = Date().addingTimeInterval(timeout * ciScale)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func hostTerminalPanelInWindow(_ panel: TerminalPanel) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try XCTUnwrap(window.contentView, "Expected content view")

        let hostedView = panel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            waitForCondition {
                panel.surface.surface != nil
            },
            "Expected runtime surface to materialize after hosting panel in a window"
        )
        return window
    }

    func testNewTerminalSplitFallsBackToRequestedWorkingDirectoryWhenReportedDirectoryIsStale() {
        let workspace = Workspace()
        guard let sourcePaneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane in new workspace")
            return
        }

        let staleCurrentDirectory = workspace.currentDirectory
        let requestedDirectory = "/tmp/programa-requested-split-cwd-\(UUID().uuidString)"
        guard let sourcePanel = workspace.newTerminalSurface(
            inPane: sourcePaneId,
            focus: false,
            workingDirectory: requestedDirectory
        ) else {
            XCTFail("Expected source terminal panel to be created")
            return
        }

        XCTAssertEqual(sourcePanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertNil(
            workspace.panelDirectories[sourcePanel.id],
            "Expected requested cwd to exist before shell integration reports a live cwd"
        )
        XCTAssertEqual(
            workspace.currentDirectory,
            staleCurrentDirectory,
            "Expected focused workspace cwd to remain stale before panel directory updates"
        )

        guard let splitPanel = workspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        XCTAssertEqual(
            splitPanel.requestedWorkingDirectory,
            requestedDirectory,
            "Expected split to inherit the source terminal's requested cwd when no reported cwd exists yet"
        )
    }

    func testNewTerminalSplitSkipsFreedInheritedSurfacePointer() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        XCTAssertNotNil(sourcePanel.surface.surface, "Expected runtime surface before forcing stale pointer")

        sourcePanel.surface.replaceSurfaceWithFreedPointerForTesting()
        XCTAssertNotNil(
            sourcePanel.surface.surface,
            "Expected Swift wrapper to remain non-nil while simulating a stale native surface"
        )

        let splitPanel = workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        XCTAssertNotNil(splitPanel, "Expected split creation to survive a stale inherited surface pointer")
        XCTAssertNil(sourcePanel.surface.surface, "Expected stale surface pointer to be quarantined")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testNewTerminalSurfaceSkipsFreedInheritedSurfacePointer() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId),
              let sourcePaneId = workspace.paneId(forPanelId: sourcePanelId) else {
            XCTFail("Expected focused terminal panel and pane")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        XCTAssertNotNil(sourcePanel.surface.surface, "Expected runtime surface before forcing stale pointer")

        sourcePanel.surface.replaceSurfaceWithFreedPointerForTesting()
        XCTAssertNotNil(
            sourcePanel.surface.surface,
            "Expected Swift wrapper to remain non-nil while simulating a stale native surface"
        )

        let createdPanel = workspace.newTerminalSurface(
            inPane: sourcePaneId,
            focus: false
        )

        XCTAssertNotNil(createdPanel, "Expected terminal creation to survive a stale inherited surface pointer")
        XCTAssertNil(sourcePanel.surface.surface, "Expected stale surface pointer to be quarantined")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    /// Regression test for the occluded-render re-land crash: 6 identical CI minidumps
    /// symbolicated to `objc_retain` `EXC_BAD_ACCESS` in
    /// `GhosttySurfaceCallbackContext.tabId.getter`, reached from
    /// `GhosttyApp.callbackContext(from:)` resolving a `ghostty_surface_userdata` pointer
    /// whose backing context had already been released by teardown. This exercises the
    /// exact stale-pointer shape: capture the live userdata pointer, tear the surface down
    /// through the real teardown path, then resolve that same pointer and assert it comes
    /// back `nil` instead of dereferencing freed memory.
    ///
    /// Mechanism note: the fix originally shipped in #262 kept a `Set` of live pointers and
    /// still dereferenced `context.tabId` (the crash site above) under the registry's lock.
    /// A follow-up made `GhosttySurfaceUserdataRegistry` own the `(surfaceId, tabId)` data
    /// directly in a dictionary keyed by pointer, so `resolve(from:)` is now a pure lookup
    /// that never dereferences the pointer as an object at all -- this test's assertions
    /// are unchanged, but the "instead of crashing" is now structurally guaranteed rather
    /// than dependent on the liveness check running before the dereference.
    func testStaleSurfaceUserdataResolvesToNilInsteadOfCrashing() throws {
#if DEBUG
        // Drives the registry directly rather than through a live ghostty surface. The
        // crash this pins -- a ghostty callback resolving userdata for an already-freed
        // surface -- lives entirely in the Swift registry/resolve path, and creating a
        // real surface needs a window server the CI runner does not provide (the earlier
        // surface-based version of this test failed at setup there while passing locally).
        // Constructing the context by hand covers the same code with no ghostty dependency.
        let surfaceId = UUID()
        let tabId = UUID()
        let unmanaged = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceId: surfaceId))
        let userdata = unmanaged.toOpaque()
        GhosttySurfaceUserdataRegistry.register(userdata, surfaceId: surfaceId, tabId: tabId)

        XCTAssertTrue(
            GhosttyApp.debugCallbackContextResolves(from: userdata),
            "Expected the live userdata pointer to resolve before teardown"
        )
        XCTAssertEqual(
            GhosttyApp.debugCallbackContextTabId(from: userdata),
            tabId,
            "Expected the registered snapshot's tabId to be visible while live"
        )

        // Same call every production teardown site now routes through.
        GhosttySurfaceUserdataRegistry.release(unmanaged)

        XCTAssertFalse(
            GhosttyApp.debugCallbackContextResolves(from: userdata),
            "Expected a stale userdata pointer to resolve to nil instead of dereferencing freed memory"
        )
        XCTAssertNil(
            GhosttyApp.debugCallbackContextTabId(from: userdata),
            "Expected no snapshot data to survive release for a stale pointer"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    /// Pins new behavior from the registry redesign: `TerminalSurface.updateWorkspaceId`
    /// must propagate the new `tabId` into `GhosttySurfaceUserdataRegistry`'s own snapshot,
    /// not just onto the (no-longer-read-by-callbacks) `GhosttySurfaceCallbackContext`
    /// instance, or a callback resolving this pointer after a workspace reassignment would
    /// see a stale `tabId`.
    func testSurfaceUserdataResolvesUpdatedTabIdAfterWorkspaceReassignment() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        guard let userdata = sourcePanel.surface.debugCallbackUserdataPointer() else {
            // Needs a real ghostty surface, which requires a window server the CI runner
            // does not provide. Skip rather than fail so this stays a meaningful local
            // check without going red in headless CI.
            throw XCTSkip("No live ghostty surface available in this environment")
        }

        let originalTabId = GhosttyApp.debugCallbackContextTabId(from: userdata)

        let reassignedTabId = UUID()
        sourcePanel.surface.updateWorkspaceId(reassignedTabId)

        XCTAssertNotEqual(
            originalTabId,
            reassignedTabId,
            "Test setup invariant: the reassigned tabId must actually differ from the original"
        )
        XCTAssertEqual(
            GhosttyApp.debugCallbackContextTabId(from: userdata),
            reassignedTabId,
            "Expected the registry's stored snapshot to reflect the reassigned tabId, since callbacks resolve tabId from the registry, not from the callback-context instance"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WorkspaceTerminalFocusRecoveryTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
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

    func testHiddenTinySelectedTerminalKeepsFocusReapplyPendingUntilLayoutIsUsable() {
        var gate = SuppressedFirstResponderFocusReapplyGate()
        let usablePortalSize = CGSize(width: 360, height: 220)
        let usableSurfaceSize = CGSize(width: 180, height: 220)

        gate.schedule()

        XCTAssertTrue(gate.isPending)
        XCTAssertFalse(
            gate.allowsFocusReassertion(
                force: false,
                isHiddenForFocus: true,
                portalSize: usablePortalSize,
                surfaceSize: usableSurfaceSize
            ),
            "A hidden selected terminal must defer Ghostty focus until it can accept input"
        )
        XCTAssertTrue(
            gate.isPending,
            "A focus request suppressed by visibility must survive until the terminal becomes usable"
        )

        XCTAssertFalse(
            gate.allowsFocusReassertion(
                force: false,
                isHiddenForFocus: false,
                portalSize: usablePortalSize,
                surfaceSize: CGSize(width: 1, height: 1)
            ),
            "A tiny terminal surface must defer Ghostty focus during layout churn"
        )
        XCTAssertTrue(
            gate.isPending,
            "A focus request suppressed by incomplete layout must remain pending"
        )

        XCTAssertTrue(
            gate.allowsFocusReassertion(
                force: false,
                isHiddenForFocus: false,
                portalSize: usablePortalSize,
                surfaceSize: usableSurfaceSize
            ),
            "The pending focus request must become eligible once visibility and layout recover"
        )
        XCTAssertTrue(
            gate.isPending,
            "Eligibility alone must not consume the request before Ghostty focus is applied"
        )

        gate.complete()
        XCTAssertFalse(
            gate.isPending,
            "A successfully applied focus request must clear the pending recovery state"
        )
    }

    func testTerminalFirstResponderConvergesSplitActiveStateWhenSelectionAlreadyMatches() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Expected the new split panel to be selected before simulating stale focus state"
        )

        // Simulate the split-pane failure mode: Bonsplit already points at the right panel,
        // but the active terminal state is still stale on the left panel.
        leftPanel.surface.setFocus(true)
        leftPanel.hostedView.setActive(true)
        rightPanel.surface.setFocus(false)
        rightPanel.hostedView.setActive(false)

        workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)

        XCTAssertFalse(
            leftPanel.hostedView.debugRenderStats().isActive,
            "Expected stale left-pane active state to be cleared"
        )
        XCTAssertTrue(
            rightPanel.hostedView.debugRenderStats().isActive,
            "Expected terminal-first-responder recovery to reactivate the selected split pane"
        )
    }

    func testTerminalClickRecoversSplitActiveStateWhenFocusCallbackIsSuppressed() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        leftPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        rightPanel.hostedView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(leftPanel.hostedView)
        contentView.addSubview(rightPanel.hostedView)

        leftPanel.hostedView.setVisibleInUI(true)
        rightPanel.hostedView.setVisibleInUI(true)
        leftPanel.hostedView.setFocusHandler {
            workspace.focusPanel(leftPanel.id, trigger: .terminalFirstResponder)
        }
        rightPanel.hostedView.setFocusHandler {
            workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Expected the clicked split pane to already be selected before simulating stale focus state"
        )

        // Simulate the ghost-terminal race: the right pane is selected in Bonsplit, but stale
        // active state remains on the left and the right pane's AppKit focus callback never fires
        // after split reparent/layout churn.
        leftPanel.surface.setFocus(true)
        leftPanel.hostedView.setActive(true)
        rightPanel.surface.setFocus(false)
        rightPanel.hostedView.setActive(false)
        rightPanel.hostedView.suppressReparentFocus()

        guard let rightSurfaceView = surfaceView(in: rightPanel.hostedView) else {
            XCTFail("Expected right terminal surface view")
            return
        }

        let pointInWindow = rightSurfaceView.convert(NSPoint(x: 24, y: 24), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window)
        rightSurfaceView.mouseDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            leftPanel.hostedView.debugRenderStats().isActive,
            "Expected clicking the selected split pane to clear stale sibling active state even when AppKit focus callbacks are suppressed"
        )
        XCTAssertTrue(
            rightPanel.hostedView.debugRenderStats().isActive,
            "Expected clicking the selected split pane to reactivate terminal input when focus callbacks are suppressed"
        )
        XCTAssertTrue(
            rightPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected the clicked split pane to become first responder"
        )
    }

    func testClearSuppressReparentFocusReassertsGhosttyFocusForCurrentFirstResponder() throws {
        // First-responder reassertion depends on real window-server semantics that
        // hosted headless runners provide nondeterministically (flips run-to-run
        // despite stable-streak retries and scaled deadlines). Covered locally.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "first-responder semantics are nondeterministic in headless CI hosts"
        )
#if DEBUG
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        leftPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        rightPanel.hostedView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(leftPanel.hostedView)
        contentView.addSubview(rightPanel.hostedView)

        leftPanel.hostedView.setVisibleInUI(true)
        rightPanel.hostedView.setVisibleInUI(true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let leftSurfaceView = surfaceView(in: leftPanel.hostedView) else {
            XCTFail("Expected left terminal surface view")
            return
        }

        leftPanel.surface.setFocus(false)
        rightPanel.surface.setFocus(true)
        leftPanel.hostedView.suppressReparentFocus()

        XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            leftPanel.surface.debugDesiredFocusState(),
            "Suppressed reparent focus should not immediately flip the Ghostty focus bit"
        )

        // newTerminalSplit's initial selection hand-off to rightPanel schedules its own
        // deferred first-responder/active-state reconciliation for leftPanel (see
        // scheduleAutomaticFirstResponderApply / resignOwnedFirstResponderIfNeeded in
        // GhosttyTerminalView.swift, reason="setActive"). That work is queued on the main
        // queue and normally drains almost immediately, well before this test's manual
        // makeFirstResponder override below. Under a full serial suite run the main queue
        // can carry a backlog of unpredictable, varying depth from hundreds of prior
        // tests, so this can fire anywhere from immediately to well over half a second
        // late — landing in between our override and clearSuppressReparentFocus() and
        // silently resigning leftSurfaceView's first-responder status back to the window
        // (confirmed via temporary diagnostic logging: firstResponder ends up the NSWindow
        // itself, and `focus.surface.resign ... reason=setActive(false)` fires immediately
        // beforehand). A fixed-duration drain isn't reliable headroom for this since the
        // backlog depth varies, so retry the override until it demonstrably survives
        // several consecutive RunLoop pumps in a row, instead of guessing a duration.
        var stableStreak = 0
        var attempts = 0
        while stableStreak < 3 && attempts < 60 {
            attempts += 1
            XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            stableStreak = leftPanel.hostedView.isSurfaceViewFirstResponder() ? stableStreak + 1 : 0
        }
        XCTAssertTrue(
            leftPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected leftSurfaceView to hold first responder stably before exercising clearSuppressReparentFocus"
        )
        leftPanel.hostedView.clearSuppressReparentFocus()
        // See the stable-streak comment above: under a full serial suite run the main
        // queue backlog varies unpredictably, so give the focus-reassert path more than
        // a hair-trigger 1s ceiling.
        let focusRecovered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                leftPanel.surface.debugDesiredFocusState()
            },
            object: NSObject()
        )
        wait(for: [focusRecovered], timeout: 10.0)
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WorkspaceTerminalConfigInheritanceSelectionTests: XCTestCase {
    func testPrefersSelectedTerminalInTargetPaneOverFocusedTerminalElsewhere() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId) else {
            XCTFail("Expected workspace split setup to succeed")
            return
        }

        // Programmatic split focuses the new right panel by default.
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: leftPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftPanelId,
            "Expected inheritance to use the selected terminal in the target pane"
        )
    }

    func testFallsBackToAnotherTerminalInPaneWhenSelectedTabIsBrowser() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected workspace browser setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: paneId)
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected inheritance to fall back to a terminal in the pane when browser is selected"
        )
    }

    func testPreferredTerminalPanelWinsWhenProvided() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a terminal panel")
            return
        }

        let sourcePanel = workspace.terminalPanelForConfigInheritance(preferredPanelId: terminalPanelId)
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testPrefersLastFocusedTerminalWhenBrowserFocusedInDifferentPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: rightPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected inheritance to prefer last focused terminal when browser is focused in another pane"
        )
    }
}


@MainActor
final class WorkspaceAttentionFlashTests: XCTestCase {
    func testMoveFocusDoesNotTriggerWholePaneFlashTokenWhenWholePaneModeEnabled() {
        let originalExperimentTarget = TmuxOverlayExperimentSettings.targetOverrideForTesting

        defer {
            TmuxOverlayExperimentSettings.targetOverrideForTesting = originalExperimentTarget
        }

        TmuxOverlayExperimentSettings.targetOverrideForTesting = .bonsplitPane

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .left)

        XCTAssertEqual(workspace.focusedPanelId, leftPanelId)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus left to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus right to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)
    }

    func testMoveFocusSuppressesWorkspacePaneFlashWhenAnotherPaneOwnsUnreadAttention() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalExperimentTarget = TmuxOverlayExperimentSettings.targetOverrideForTesting
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            TmuxOverlayExperimentSettings.targetOverrideForTesting = originalExperimentTarget
        }

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        AppFocusState.overrideIsFocused = true
        TmuxOverlayExperimentSettings.targetOverrideForTesting = .bonsplitPane

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        workspace.moveFocus(direction: .left)

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Unread",
            subtitle: "",
            body: "Left pane owns notification attention"
        )

        XCTAssertTrue(
            notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId),
            "Expected the left pane to own visible notification attention before moving focus"
        )

        let flashTokenBeforeNavigation = workspace.tmuxWorkspaceFlashToken

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            flashTokenBeforeNavigation,
            "Expected navigation flash to be suppressed while another pane owns notification attention"
        )
    }
}


@MainActor
final class WorkspaceBrowserProfileSelectionTests: XCTestCase {
    private final class RejectingCreateTabDelegate: BonsplitDelegate {
        func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
            false
        }
    }

    private final class RejectingSplitPaneDelegate: BonsplitDelegate {
        func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
            false
        }
    }

    func testNewBrowserSurfacePrefersSelectedBrowserProfileInTargetPane() throws {
        let workspace = Workspace()
        let profileA = try makeTemporaryBrowserProfile(named: "Alpha")
        let profileB = try makeTemporaryBrowserProfile(named: "Beta")
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let browserA = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: true,
                preferredProfileID: profileA.id
            )
        )
        _ = try XCTUnwrap(
            workspace.newBrowserSplit(
                from: browserA.id,
                orientation: .horizontal,
                preferredProfileID: profileB.id,
                focus: true
            )
        )

        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            profileB.id,
            "Expected workspace preference to drift to the most recently created browser profile"
        )

        let leftSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(browserA.id))
        workspace.bonsplitController.focusPane(paneId)
        workspace.bonsplitController.selectTab(leftSurfaceId)

        let created = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: false
            )
        )

        XCTAssertEqual(
            created.profileID,
            profileA.id,
            "Expected new browser creation to inherit the selected browser profile from the target pane"
        )
    }

    func testNewBrowserSurfaceFailureDoesNotMutatePreferredProfile() throws {
        let workspace = Workspace()
        let preferredProfile = try makeTemporaryBrowserProfile(named: "Preferred")
        let unexpectedProfile = try makeTemporaryBrowserProfile(named: "Unexpected")

        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        _ = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: false,
                preferredProfileID: preferredProfile.id
            )
        )
        XCTAssertEqual(workspace.preferredBrowserProfileID, preferredProfile.id)

        let rejectingDelegate = RejectingCreateTabDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate
        let created = workspace.newBrowserSurface(
            inPane: paneId,
            focus: false,
            preferredProfileID: unexpectedProfile.id
        )

        XCTAssertNil(created)
        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            preferredProfile.id,
            "Expected a failed browser creation to leave the workspace preferred profile unchanged"
        )
    }

    func testNewBrowserSplitFailureDoesNotMutatePreferredProfile() throws {
        let workspace = Workspace()
        let preferredProfile = try makeTemporaryBrowserProfile(named: "Preferred")
        let unexpectedProfile = try makeTemporaryBrowserProfile(named: "Unexpected")

        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let browser = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: true,
                preferredProfileID: preferredProfile.id
            )
        )
        XCTAssertEqual(workspace.preferredBrowserProfileID, preferredProfile.id)

        let rejectingDelegate = RejectingSplitPaneDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate
        let created = workspace.newBrowserSplit(
            from: browser.id,
            orientation: .horizontal,
            preferredProfileID: unexpectedProfile.id,
            focus: false
        )

        XCTAssertNil(created)
        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            preferredProfile.id,
            "Expected a failed browser split to leave the workspace preferred profile unchanged"
        )
    }
}


@MainActor
final class WorkspacePanelGitBranchTests: XCTestCase {
    private func drainMainQueue() {
        // A fixed 1s wait isn't reliable headroom for this main-queue turn under a full
        // serial suite run, where the queue can carry a real backlog from hundreds of
        // prior tests' pending async work.
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    private func assertPanelAndTabTitle(
        _ expected: String,
        workspace: Workspace,
        panelId: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(workspace.panelTitle(panelId: panelId), expected, file: file, line: line)
        guard let tabId = workspace.surfaceIdFromPanelId(panelId),
              let tab = workspace.bonsplitController.tab(tabId) else {
            XCTFail("Expected panel to have a Bonsplit tab", file: file, line: line)
            return
        }
        XCTAssertEqual(tab.title, expected, file: file, line: line)
    }

    func testPanelTitleUsesPRTicketBranchManualPrecedenceWithoutRenamingWorkspace() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let pullRequestURL = try XCTUnwrap(URL(string: "https://github.com/darkroomengineering/programa/pull/482"))

        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "agent-shell"))
        let workspaceTitle = workspace.title
        assertPanelAndTabTitle("agent-shell", workspace: workspace, panelId: panelId)

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/PROG-123-summary",
            isDirty: false
        )
        assertPanelAndTabTitle("PROG-123", workspace: workspace, panelId: panelId)
        XCTAssertEqual(workspace.title, workspaceTitle)

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 482,
            label: "Improve tab names",
            url: pullRequestURL,
            status: .open,
            branch: "feature/PROG-123-summary"
        )
        assertPanelAndTabTitle("PR #482", workspace: workspace, panelId: panelId)
        XCTAssertEqual(workspace.title, workspaceTitle)

        workspace.setPanelCustomTitle(panelId: panelId, title: "  Manual lane  ")
        assertPanelAndTabTitle("Manual lane", workspace: workspace, panelId: panelId)

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/OPS9-77-follow-up",
            isDirty: true
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 483,
            label: "Follow-up",
            url: pullRequestURL,
            status: .open,
            branch: "feature/OPS9-77-follow-up"
        )
        assertPanelAndTabTitle("Manual lane", workspace: workspace, panelId: panelId)

        workspace.setPanelCustomTitle(panelId: panelId, title: nil)
        assertPanelAndTabTitle("PR #483", workspace: workspace, panelId: panelId)

        workspace.clearPanelPullRequest(panelId: panelId)
        assertPanelAndTabTitle("OPS9-77", workspace: workspace, panelId: panelId)

        workspace.clearPanelGitBranch(panelId: panelId)
        assertPanelAndTabTitle("agent-shell", workspace: workspace, panelId: panelId)
        XCTAssertEqual(
            workspace.title,
            workspaceTitle,
            "Panel metadata must not rename the workspace shown in the sidebar"
        )
    }

    func testAutomaticPanelTitleUsesOnlyConservativeUppercaseTicketTokens() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "live-process"))
        let workspaceTitle = workspace.title

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "  feature/lowercase-summary  ",
            isDirty: false
        )
        assertPanelAndTabTitle(
            "feature/lowercase-summary",
            workspace: workspace,
            panelId: panelId
        )

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/prog-123-summary",
            isDirty: false
        )
        assertPanelAndTabTitle(
            "feature/prog-123-summary",
            workspace: workspace,
            panelId: panelId
        )

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/PROG-123-summary",
            isDirty: false
        )
        assertPanelAndTabTitle("PROG-123", workspace: workspace, panelId: panelId)
        XCTAssertEqual(workspace.title, workspaceTitle)
    }

    func testPanelTitleUsesOnlyPullRequestMetadataScopedToTheCurrentBranch() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let pullRequestURL = try XCTUnwrap(URL(string: "https://github.com/darkroomengineering/programa/pull/484"))

        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "live-process"))
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 484,
            label: "Other lane",
            url: pullRequestURL,
            status: .open,
            branch: "feature/OTHER-484-summary"
        )
        assertPanelAndTabTitle(
            "live-process",
            workspace: workspace,
            panelId: panelId
        )

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/CURRENT-21-summary",
            isDirty: false
        )
        assertPanelAndTabTitle("CURRENT-21", workspace: workspace, panelId: panelId)

        workspace.clearPanelGitBranch(panelId: panelId)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 485,
            label: "Unscoped lane",
            url: pullRequestURL,
            status: .open
        )
        assertPanelAndTabTitle(
            "PR #485",
            workspace: workspace,
            panelId: panelId,
            file: #filePath,
            line: #line
        )
    }

    func testResetSidebarContextClearsAutomaticPanelTitlesButPreservesManualNames() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let pullRequestURL = try XCTUnwrap(URL(string: "https://github.com/darkroomengineering/programa/pull/486"))

        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "live-process"))
        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/RESET-12-summary",
            isDirty: false
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 486,
            label: "Reset lane",
            url: pullRequestURL,
            status: .open,
            branch: "feature/RESET-12-summary"
        )
        assertPanelAndTabTitle("PR #486", workspace: workspace, panelId: panelId)

        workspace.resetSidebarContext(reason: "test")
        assertPanelAndTabTitle("live-process", workspace: workspace, panelId: panelId)

        workspace.setPanelCustomTitle(panelId: panelId, title: "Manual lane")
        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/RESET-13-summary",
            isDirty: false
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 487,
            label: "Reset manual lane",
            url: pullRequestURL,
            status: .open,
            branch: "feature/RESET-13-summary"
        )

        workspace.resetSidebarContext(reason: "test-manual")
        assertPanelAndTabTitle("Manual lane", workspace: workspace, panelId: panelId)
    }

    func testDetachAttachDoesNotPersistAutomaticPanelTitleButPreservesManualName() throws {
        let source = Workspace()
        let destination = Workspace()
        let finalDestination = Workspace()
        defer {
            source.teardownAllPanels()
            destination.teardownAllPanels()
            finalDestination.teardownAllPanels()
        }
        let panelId = try XCTUnwrap(source.focusedPanelId)
        let pullRequestURL = try XCTUnwrap(URL(string: "https://github.com/darkroomengineering/programa/pull/488"))

        XCTAssertTrue(source.updatePanelTitle(panelId: panelId, title: "live-process"))
        source.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/MOVE-33-summary",
            isDirty: false
        )
        source.updatePanelPullRequest(
            panelId: panelId,
            number: 488,
            label: "Move lane",
            url: pullRequestURL,
            status: .open,
            branch: "feature/MOVE-33-summary"
        )
        assertPanelAndTabTitle("PR #488", workspace: source, panelId: panelId)

        let detachedAutomatic = try XCTUnwrap(source.detachSurface(panelId: panelId))
        let destinationPane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertEqual(
            destination.attachDetachedSurface(detachedAutomatic, inPane: destinationPane, focus: false),
            panelId
        )
        assertPanelAndTabTitle(
            "live-process",
            workspace: destination,
            panelId: panelId
        )

        destination.setPanelCustomTitle(panelId: panelId, title: "Manual moved lane")
        let detachedManual = try XCTUnwrap(destination.detachSurface(panelId: panelId))
        let finalPane = try XCTUnwrap(finalDestination.bonsplitController.allPaneIds.first)
        XCTAssertEqual(
            finalDestination.attachDetachedSurface(detachedManual, inPane: finalPane, focus: false),
            panelId
        )
        assertPanelAndTabTitle(
            "Manual moved lane",
            workspace: finalDestination,
            panelId: panelId
        )
    }

    func testSessionRestoreKeepsRawLiveTitleSeparateFromAutomaticAndManualTitles() throws {
        let source = Workspace()
        let restored = Workspace()
        defer {
            source.teardownAllPanels()
            restored.teardownAllPanels()
        }
        let panelId = try XCTUnwrap(source.focusedPanelId)

        XCTAssertTrue(source.updatePanelTitle(panelId: panelId, title: "live-process"))
        source.updatePanelGitBranch(
            panelId: panelId,
            branch: "feature/RESTORE-91-summary",
            isDirty: false
        )
        source.setPanelCustomTitle(panelId: panelId, title: "Manual restored lane")

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(
            panelSnapshot.title,
            "live-process",
            "The persisted base title must remain the live title so transient metadata cannot become stale state"
        )
        XCTAssertEqual(panelSnapshot.customTitle, "Manual restored lane")
        XCTAssertEqual(panelSnapshot.gitBranch?.branch, "feature/RESTORE-91-summary")

        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        assertPanelAndTabTitle(
            "Manual restored lane",
            workspace: restored,
            panelId: restoredPanelId
        )

        restored.setPanelCustomTitle(panelId: restoredPanelId, title: nil)
        assertPanelAndTabTitle("RESTORE-91", workspace: restored, panelId: restoredPanelId)

        restored.clearPanelGitBranch(panelId: restoredPanelId)
        assertPanelAndTabTitle("live-process", workspace: restored, panelId: restoredPanelId)
    }

    func testBrowserSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(browserSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser split to preserve pre-split focus"
        )
    }

    func testTerminalSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let terminalSplitPanel = workspace.newTerminalSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected terminal split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(terminalSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal split to preserve pre-split focus"
        )
    }

    func testDetachLastSurfaceLeavesWorkspaceTemporarilyEmptyForMoveFlow() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected initial panel and pane")
            return
        }

        XCTAssertEqual(workspace.panels.count, 1)
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach of last surface to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, panelId)
        XCTAssertTrue(
            workspace.panels.isEmpty,
            "Detaching the last surface should not auto-create a replacement panel"
        )
        XCTAssertNil(workspace.surfaceIdFromPanelId(panelId))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: paneId).count, 0)

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching during cross-workspace moves should not schedule delayed source focus reconciliation"
        )
#endif

        let restoredPanelId = workspace.attachDetachedSurface(detached, inPane: paneId, focus: false)
        XCTAssertEqual(restoredPanelId, panelId)
        XCTAssertEqual(workspace.panels.count, 1)
    }

    func testDetachSurfaceWithRemainingPanelsSkipsDelayedFocusReconcile() {
        let workspace = Workspace()
        guard let originalPanelId = workspace.focusedPanelId,
              let movedPanel = workspace.newTerminalSplit(from: originalPanelId, orientation: .horizontal) else {
            XCTFail("Expected two panels before detach")
            return
        }

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: movedPanel.id) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, movedPanel.id)
        XCTAssertEqual(workspace.panels.count, 1, "Expected source workspace to retain only the surviving panel")
        XCTAssertNotNil(workspace.panels[originalPanelId], "Expected the original panel to remain after detach")

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching into another workspace should not enqueue delayed source focus reconciliation"
        )
#endif
    }

    func testDetachAttachAcrossWorkspacesPreservesNonCustomPanelTitle() {
        let source = Workspace()
        guard let panelId = source.focusedPanelId else {
            XCTFail("Expected source focused panel")
            return
        }

        XCTAssertTrue(source.updatePanelTitle(panelId: panelId, title: "detached-runtime-title"))

        guard let detached = source.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.cachedTitle, "detached-runtime-title")
        XCTAssertNil(detached.customTitle)
        XCTAssertEqual(
            detached.title,
            "detached-runtime-title",
            "Detached transfer should carry the cached non-custom title"
        )

        let destination = Workspace()
        guard let destinationPane = destination.bonsplitController.allPaneIds.first else {
            XCTFail("Expected destination pane")
            return
        }

        let attachedPanelId = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )
        XCTAssertEqual(attachedPanelId, panelId)
        XCTAssertEqual(destination.panelTitle(panelId: panelId), "detached-runtime-title")

        guard let attachedTabId = destination.surfaceIdFromPanelId(panelId),
              let attachedTab = destination.bonsplitController.tab(attachedTabId) else {
            XCTFail("Expected attached tab mapping")
            return
        }
        XCTAssertEqual(attachedTab.title, "detached-runtime-title")
        XCTAssertFalse(attachedTab.hasCustomTitle)
    }

    func testLocalBrowserTransferInvalidatesRestoreWithoutReplacingWebViewOrDataStore() throws {
        let source = Workspace()
        let destination = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let browserPanel = try XCTUnwrap(
            source.newBrowserSplit(
                from: sourcePanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        var activeLease: TerminalController.V2BrowserStateRestoreLeaseCoordinator.Lease?
        defer {
            if let activeLease {
                browserPanel.endBrowserStateRestore(activeLease)
            }
            source.teardownAllPanels()
            destination.teardownAllPanels()
        }

        let originalWebView = browserPanel.webView
        let originalDataStore = originalWebView.configuration.websiteDataStore
        let detachLease = try XCTUnwrap(browserPanel.beginBrowserStateRestore())
        activeLease = detachLease

        let detached = try XCTUnwrap(source.detachSurface(panelId: browserPanel.id))
        XCTAssertTrue(browserPanel.webView === originalWebView)
        XCTAssertTrue(browserPanel.webView.configuration.websiteDataStore === originalDataStore)
        XCTAssertFalse(
            browserPanel.isBrowserStateRestoreLeaseValid(detachLease),
            "Detaching must invalidate an in-flight restore even when the browser objects survive"
        )
        browserPanel.endBrowserStateRestore(detachLease)
        activeLease = nil

        let reattachLease = try XCTUnwrap(browserPanel.beginBrowserStateRestore())
        activeLease = reattachLease
        let destinationPane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false),
            browserPanel.id
        )
        XCTAssertTrue(browserPanel.webView === originalWebView)
        XCTAssertTrue(browserPanel.webView.configuration.websiteDataStore === originalDataStore)
        XCTAssertFalse(
            browserPanel.isBrowserStateRestoreLeaseValid(reattachLease),
            "Reattaching must defensively invalidate a restore when the local profile keeps the same data store"
        )
        browserPanel.endBrowserStateRestore(reattachLease)
        activeLease = nil
    }

    func testBrowserElementRefSurvivesDetachAndAttachThenExpiresOnPermanentTeardown() throws {
        let source = Workspace()
        let destination = Workspace()
        var transferredSurfaceId: UUID?
        defer {
            source.teardownAllPanels()
            destination.teardownAllPanels()
            if let transferredSurfaceId {
                TerminalController.shared.v2BrowserPermanentlyRemoveSurfaceState(surfaceId: transferredSurfaceId)
            }
        }

        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let browserPanel = try XCTUnwrap(
            source.newBrowserSplit(
                from: sourcePanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        transferredSurfaceId = browserPanel.id
        let ref: String
        switch TerminalController.shared.browserRPCState.allocateElementRefs(
            surfaceId: browserPanel.id,
            selectors: ["#survives-workspace-transfer"]
        ) {
        case .allocated(let refs):
            ref = try XCTUnwrap(refs.first)
        case .resourceExhausted:
            XCTFail("A new browser panel must accept its first element ref")
            return
        }
        XCTAssertEqual(
            TerminalController.shared.v2BrowserResolveSelector(ref, surfaceId: browserPanel.id),
            "#survives-workspace-transfer"
        )

        let detached = try XCTUnwrap(source.detachSurface(panelId: browserPanel.id))
        XCTAssertNil(source.panels[browserPanel.id])
        XCTAssertEqual(
            TerminalController.shared.v2BrowserResolveSelector(ref, surfaceId: browserPanel.id),
            "#survives-workspace-transfer",
            "Detaching for transfer must preserve browser automation state"
        )

        let destinationPane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false),
            browserPanel.id
        )
        XCTAssertTrue(destination.panels[browserPanel.id] is BrowserPanel)
        XCTAssertEqual(
            TerminalController.shared.v2BrowserResolveSelector(ref, surfaceId: browserPanel.id),
            "#survives-workspace-transfer",
            "Attaching the same browser panel must preserve its existing ref identity"
        )

        destination.teardownAllPanels()
        switch TerminalController.shared.v2BrowserSelectorResolutionError(ref, surfaceId: browserPanel.id) {
        case .err(let code, _, _):
            XCTAssertEqual(code, "not_found", "Permanent workspace teardown must remove the transferred browser ref")
        case .ok:
            XCTFail("A permanently closed browser panel ref must not remain resolvable")
        }
    }

    func testDetachedBrowserResolutionRollsBackAfterInvalidPrimaryWithoutLosingState() throws {
        let source = Workspace()
        let destination = Workspace()
        defer {
            source.teardownAllPanels()
            destination.teardownAllPanels()
        }
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let browserPanel = try XCTUnwrap(source.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, focus: false))
        let sourceRollbackPane = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let transfer = try XCTUnwrap(source.detachSurface(panelId: browserPanel.id))
        let ref: String
        switch TerminalController.shared.browserRPCState.allocateElementRefs(surfaceId: browserPanel.id, selectors: ["#rollback-ref"]) {
        case .allocated(let refs): ref = try XCTUnwrap(refs.first)
        case .resourceExhausted: return XCTFail("Expected a fresh browser ref")
        }

        let result = transfer.resolve(
            primary: Workspace.DetachedSurfaceAttachmentTarget(
                workspace: destination,
                paneId: PaneID(),
                index: nil,
                focus: false
            ),
            rollback: Workspace.DetachedSurfaceAttachmentTarget(
                workspace: source,
                paneId: sourceRollbackPane,
                index: nil,
                focus: false
            )
        )

        guard case .attachedRollback(let panelId) = result else {
            return XCTFail("Expected invalid primary attachment to use the valid source rollback")
        }
        XCTAssertEqual(panelId, browserPanel.id)
        XCTAssertTrue((source.panels[browserPanel.id] as? BrowserPanel) === browserPanel)
        XCTAssertNil(destination.panels[browserPanel.id])
        XCTAssertEqual(TerminalController.shared.v2BrowserResolveSelector(ref, surfaceId: browserPanel.id), "#rollback-ref")
    }

    func testDetachedBrowserResolutionFinalizesWhenPrimaryAndRollbackAreInvalid() throws {
        let source = Workspace()
        let destination = Workspace()
        defer {
            source.teardownAllPanels()
            destination.teardownAllPanels()
        }
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let browserPanel = try XCTUnwrap(source.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, focus: false))
        let transfer = try XCTUnwrap(source.detachSurface(panelId: browserPanel.id))
        let ref: String
        switch TerminalController.shared.browserRPCState.allocateElementRefs(surfaceId: browserPanel.id, selectors: ["#finalized-ref"]) {
        case .allocated(let refs): ref = try XCTUnwrap(refs.first)
        case .resourceExhausted: return XCTFail("Expected a fresh browser ref")
        }

        let result = transfer.resolve(
            primary: Workspace.DetachedSurfaceAttachmentTarget(workspace: destination, paneId: PaneID(), index: nil, focus: false),
            rollback: Workspace.DetachedSurfaceAttachmentTarget(workspace: source, paneId: PaneID(), index: nil, focus: false)
        )

        guard case .finalized = result else {
            return XCTFail("A transfer with no valid attachment owner must finalize")
        }
        XCTAssertNil(source.panels[browserPanel.id])
        XCTAssertNil(destination.panels[browserPanel.id])
        XCTAssertNil(browserPanel.webView.navigationDelegate, "Finalization must close and disable the detached browser panel")
        switch TerminalController.shared.v2BrowserSelectorResolutionError(ref, surfaceId: browserPanel.id) {
        case .err(let code, _, _): XCTAssertEqual(code, "not_found")
        case .ok: XCTFail("Finalization must permanently remove browser ref state")
        }
        transfer.finalizePermanently()
        XCTAssertNil(browserPanel.webView.navigationDelegate, "Repeated finalization must remain idempotent")
    }

    func testAttachedTransferIgnoresStaleFinalizeAndNextDetachHasIndependentOwnership() throws {
        let source = Workspace()
        let destination = Workspace()
        defer {
            source.teardownAllPanels()
            destination.teardownAllPanels()
        }
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let browserPanel = try XCTUnwrap(source.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, focus: false))
        let transfer = try XCTUnwrap(source.detachSurface(panelId: browserPanel.id))
        let destinationPane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let ref: String
        switch TerminalController.shared.browserRPCState.allocateElementRefs(surfaceId: browserPanel.id, selectors: ["#attached-ref"]) {
        case .allocated(let refs): ref = try XCTUnwrap(refs.first)
        case .resourceExhausted: return XCTFail("Expected a fresh browser ref")
        }

        let result = transfer.resolve(
            primary: Workspace.DetachedSurfaceAttachmentTarget(
                workspace: destination,
                paneId: destinationPane,
                index: nil,
                focus: false
            ),
            rollback: nil
        )
        guard case .attachedPrimary(let panelId) = result else {
            return XCTFail("Expected the valid primary destination to own the panel")
        }
        XCTAssertEqual(panelId, browserPanel.id)

        transfer.finalizePermanently()
        XCTAssertTrue((destination.panels[browserPanel.id] as? BrowserPanel) === browserPanel)
        XCTAssertNotNil(browserPanel.webView.navigationDelegate)
        XCTAssertEqual(TerminalController.shared.v2BrowserResolveSelector(ref, surfaceId: browserPanel.id), "#attached-ref")

        let nextTransfer = try XCTUnwrap(destination.detachSurface(panelId: browserPanel.id))
        XCTAssertFalse(nextTransfer === transfer, "A later detach must have a new pending lifecycle owner")
        nextTransfer.finalizePermanently()
        switch TerminalController.shared.v2BrowserSelectorResolutionError(ref, surfaceId: browserPanel.id) {
        case .err(let code, _, _): XCTAssertEqual(code, "not_found")
        case .ok: XCTFail("Finalizing the new pending transfer must remove its browser ref")
        }
    }

    func testBrowserSplitWithFocusFalseRecoversFromDelayedStaleSelection() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }
        guard let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected focused pane for initial panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }
        guard let splitPaneId = workspace.paneId(forPanelId: browserSplitPanel.id),
              let splitTabId = workspace.surfaceIdFromPanelId(browserSplitPanel.id),
              let splitTab = workspace.bonsplitController
              .tabs(inPane: splitPaneId)
              .first(where: { $0.id == splitTabId }) else {
            XCTFail("Expected split pane/tab mapping")
            return
        }

        // Simulate one delayed stale split-selection callback from bonsplit.
        DispatchQueue.main.async {
            workspace.splitTabBar(workspace.bonsplitController, didSelectTab: splitTab, inPane: splitPaneId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus split to reassert the pre-split focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.focusedPaneId,
            originalPaneId,
            "Expected focused pane to converge back to the pre-split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to converge back to the pre-split focused panel"
        )
    }

    func testBrowserSplitWithFocusFalseAllowsSubsequentExplicitFocusOnSplitPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        workspace.focusPanel(browserSplitPanel.id)

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            browserSplitPanel.id,
            "Expected explicit focus intent to keep the split panel focused"
        )
    }

    func testNewTerminalSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel and pane")
            return
        }

        guard let newPanel = workspace.newTerminalSurface(inPane: originalPaneId, focus: false) else {
            XCTFail("Expected terminal surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to stay on the original focused panel"
        )
    }

    func testNewBrowserSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel and pane")
            return
        }

        guard let newPanel = workspace.newBrowserSurface(inPane: originalPaneId, focus: false) else {
            XCTFail("Expected browser surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to stay on the original focused panel"
        )
    }

    func testClosingFocusedSplitRestoresBranchForRemainingFocusedPanel() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        guard let secondPanel = workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/bugfix", isDirty: true)
        XCTAssertEqual(workspace.focusedPanelId, secondPanel.id, "Expected split panel to be focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/bugfix")
        XCTAssertEqual(workspace.gitBranch?.isDirty, true)

        XCTAssertTrue(workspace.closePanel(secondPanel.id, force: true), "Expected split panel close to succeed")
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Expected surviving panel to become focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, false)
    }

    func testSidebarGitBranchesFollowLeftToRightSplitOrder() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "main", isDirty: false)
        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "feature/sidebar", isDirty: true)

        let ordered = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(ordered.map(\.branch), ["main", "feature/sidebar"])
        XCTAssertEqual(ordered.map(\.isDirty), [false, true])
    }

    func testUpdatingFocusedPanelGitBranchWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount

        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected the first focused branch update to publish workspace changes"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical focused branch refreshes to avoid extra workspace publishes"
        )
    }

    func testUpdatingFocusedPanelPullRequestWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/sidebar-pr", isDirty: false)

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/2388")!
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )
        let baselinePublishCount = publishCount

        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected the first focused pull request update to publish workspace changes"
        )

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical focused pull request refreshes to avoid extra workspace publishes"
        )
    }

    func testSidebarObservationPublisherEmitsForFocusedGitBranchChangesOnlyOncePerState() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount
        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected focused git branch updates to invalidate sidebar rows"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical git metadata refreshes to be ignored by sidebar rows"
        )
    }

    // Renamed from testSidebarPullRequestsTrackFocusedPanelOnly. That name asserted a
    // focused-only filter that never existed in production: `sidebarPullRequestsInDisplayOrder()`
    // has surfaced PRs for every panel in sidebar order since it was introduced (commit
    // 2d454df5, "feat(sidebar): show linked pull request metadata"), mirroring the pre-existing
    // multi-panel `sidebarGitBranchesInDisplayOrder()`. The perf-only precompute in f7388715
    // ("Precompute panel ordering to reduce sidebar scroll lag") didn't change that. And the
    // recent poll-candidate fix (commit d94d79ee, "fix: PR-probe filtering, poll candidates...")
    // together with the green `TabManagerPullRequestProbeTests
    // .testTrackedWorkspaceGitMetadataPollCandidatesIncludeMainAndMasterPanels` test explicitly
    // proves background/non-main panels (master, feature, mainline splits) are polled for PR
    // metadata -- which would be pointless if the sidebar only ever displayed the focused panel's
    // PR. This test now documents the real contract: background panels with a valid,
    // branch-matched PR are shown in sidebar order; PRs whose recorded branch no longer matches
    // the panel's current git branch are filtered out.
    @MainActor
    func testSidebarPullRequestsShowAllPanelsInSidebarOrderFilteringBranchMismatches() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let secondPanel = workspace.newTerminalSurface(inPane: paneId, focus: false),
              let thirdPanel = workspace.newTerminalSurface(inPane: paneId, focus: false),
              let fourthPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected focused panel and three background panels")
            return
        }

        // newTerminalSurface(focus: false) inserts each new tab right after the pane's current
        // tab (bonsplit's `newTabPosition: .current`), not appended at the end -- so pin down a
        // deterministic left-to-right order explicitly instead of relying on insertion order.
        XCTAssertTrue(workspace.reorderSurface(panelId: firstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: secondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: thirdPanel.id, toIndex: 2))
        XCTAssertTrue(workspace.reorderSurface(panelId: fourthPanel.id, toIndex: 3))
        // reorderSurface() selects the reordered tab as a side effect; restore focus to the
        // first panel so it's the focused panel for the rest of this test.
        workspace.focusPanel(firstPanelId)

        // Focused panel has no PR at all.
        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)

        // Background panel with a PR whose recorded branch matches its current git branch.
        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: secondPanel.id,
            number: 1629,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1629")!,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        // Background panel whose PR's recorded branch no longer matches the panel's current git
        // branch (e.g. the panel checked out a different branch after the PR was probed) --
        // this stale PR must be filtered out of the sidebar.
        workspace.updatePanelGitBranch(panelId: thirdPanel.id, branch: "feature/mismatch", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: thirdPanel.id,
            number: 999,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/999")!,
            status: .open,
            branch: "totally-different-branch"
        )

        // A second background panel with a valid, branch-matched PR, to prove ordering follows
        // sidebar order rather than focus or insertion order.
        workspace.updatePanelGitBranch(panelId: fourthPanel.id, branch: "feature/second-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: fourthPanel.id,
            number: 1750,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1750")!,
            status: .open,
            branch: "feature/second-pr"
        )

        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Focus should never have moved")
        XCTAssertNil(workspace.pullRequest, "Focused panel never had a PR of its own")

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [firstPanelId, secondPanel.id, thirdPanel.id, fourthPanel.id]
        )
        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder().map(\.number),
            [1629, 1750],
            "Expected background panels' branch-matched PRs to show in sidebar order while the " +
            "focused panel contributes nothing and the branch-mismatched PR is filtered out"
        )
    }

    func testSidebarOrderingUsesPaneOrderThenTabOrderWithBranchDeduping() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for ordering test")
            return
        }

        XCTAssertTrue(workspace.reorderSurface(panelId: leftFirstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: leftSecondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightFirstPanel.id, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightSecondPanel.id, toIndex: 1))

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "main", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightSecondPanel.id, branch: "feature/right", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [leftFirstPanelId, leftSecondPanel.id, rightFirstPanel.id, rightSecondPanel.id]
        )

        let branches = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(branches.map(\.branch), ["main", "feature/left", "feature/right"])
        XCTAssertEqual(branches.map(\.isDirty), [true, false, false])
    }

    func testSidebarBranchDirectoryEntriesStayStableAcrossFocusedSplitChanges() {
        let workspace = Workspace()
        let leftLiveDirectory = "/repo/left/live"
        let rightFocusedDirectory = "/repo/right/focused"
        let leftFocusedDirectory = "/repo/left/focused"
        let rightRequestedDirectory = "/repo/right/requested"

        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelDirectory(panelId: leftPanelId, directory: leftLiveDirectory)

        guard let rightSplitPanel = workspace.newTerminalSplit(
            from: leftPanelId,
            orientation: .horizontal,
            focus: false
        ),
        let rightPaneId = workspace.paneId(forPanelId: rightSplitPanel.id),
        let rightRequestedPanel = workspace.newTerminalSurface(
            inPane: rightPaneId,
            focus: false,
            workingDirectory: rightRequestedDirectory
        ) else {
            XCTFail("Expected right split panes for sidebar directory ordering test")
            return
        }

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [leftPanelId, rightSplitPanel.id, rightRequestedPanel.id])

        workspace.currentDirectory = rightFocusedDirectory
        let entriesWhenRightLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        workspace.currentDirectory = leftFocusedDirectory
        let entriesWhenLeftLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        XCTAssertEqual(
            entriesWhenRightLooksFocused,
            entriesWhenLeftLooksFocused,
            "Expected sidebar directory ordering to ignore focused-workspace cwd churn when panel-specific directories are available"
        )
        XCTAssertEqual(
            entriesWhenRightLooksFocused.map(\.directory),
            [leftLiveDirectory, rightRequestedDirectory]
        )
    }

    func testSidebarDerivedCollectionsMatchWhenUsingPrecomputedPanelOrder() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for precomputed ordering test")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "release/right", isDirty: false)

        workspace.updatePanelDirectory(panelId: leftFirstPanelId, directory: "/repo/left/root")
        workspace.updatePanelDirectory(panelId: leftSecondPanel.id, directory: "/repo/left/feature")
        workspace.updatePanelDirectory(panelId: rightFirstPanel.id, directory: "/repo/right/root")
        workspace.updatePanelDirectory(panelId: rightSecondPanel.id, directory: "/repo/right/extra")

        workspace.updatePanelPullRequest(
            panelId: leftFirstPanelId,
            number: 101,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/101")!,
            status: .open
        )
        workspace.updatePanelPullRequest(
            panelId: rightFirstPanel.id,
            number: 18,
            label: "MR",
            url: URL(string: "https://gitlab.com/manaflow/cmux/-/merge_requests/18")!,
            status: .merged
        )

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()

        XCTAssertEqual(
            workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { "\($0.branch)|\($0.isDirty)" },
            workspace.sidebarGitBranchesInDisplayOrder().map { "\($0.branch)|\($0.isDirty)" }
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder()
        )
        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarPullRequestsInDisplayOrder()
        )
    }

    func testClosingPaneDropsBranchesFromClosedSide() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected left/right split panes")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "branch1", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "branch2", isDirty: false)

        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch1", "branch2"])
        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch2"])
    }

    func testClosingPaneClearsNotificationsForClosedPanels() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.notificationStore = originalStore
        }

        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected left/right split panes")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "left",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: leftPanelId))

        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))

        XCTAssertFalse(
            store.hasUnreadNotification(forTabId: workspace.id, surfaceId: leftPanelId),
            "Closing a pane must clear notifications for its panels, same as closing a single surface"
        )
    }
}


final class WorkspaceMountPolicyTests: XCTestCase {
    func testDefaultPolicyMountsOnlySelectedWorkspace() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspaces
        )

        XCTAssertEqual(next, [b])
    }

    func testSelectedWorkspaceMovesToFrontAndMountCountIsBounded() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b, c],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [c, a])
    }

    func testMissingWorkspacesArePruned() {
        let a = UUID()
        let b = UUID()

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [b, a],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: [a],
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [a])
    }

    func testSelectedWorkspaceIsInsertedWhenAbsentFromCurrentCache() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [b, a])
    }

    func testMaxMountedIsClampedToAtLeastOne() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 0
        )

        XCTAssertEqual(next, [a])
    }

    func testCycleHotModeKeepsOnlySelectedWhenNoPinnedHandoff() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let orderedTabIds: [UUID] = [a, b, c, d]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        )

        XCTAssertEqual(next, [c])
    }

    func testCycleHotModeRespectsMaxMountedLimit() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b, c],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: 2
        )

        XCTAssertEqual(next, [b])
    }

    func testPinnedIdsAreRetainedAcrossReconcile() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: c,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [c, a])
    }

    func testCycleHotModeKeepsRetiringWorkspaceWhenPinned() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        )

        XCTAssertEqual(next, [b, a])
    }
}

/// Regression coverage for docs/audits/codebase-audit-2026-09-11.md M13: moving a review or
/// markdown panel between workspaces must reinstall its workspace binding and lifecycle
/// subscription, and a review panel's auto-refresh trigger must keep tracking whichever
/// workspace actually holds its source terminal, even after the two panels are split across
/// different workspaces.
@MainActor
final class ReviewPanelWorkspaceTransferTests: XCTestCase {
    private var originalSharedAppDelegate: AppDelegate?

    override func setUp() {
        super.setUp()
        originalSharedAppDelegate = AppDelegate.shared
    }

    override func tearDown() {
        AppDelegate.shared = originalSharedAppDelegate
        super.tearDown()
    }

    /// Registers `workspaces` on a single `TabManager` inside a fresh `AppDelegate`, installed
    /// as `AppDelegate.shared`, so `Workspace.workspaceOwning(surfaceId:)` (used by
    /// `installReviewPanelSubscription` and `ReviewPanel.sendToSourceSurface`) can locate them
    /// the same way production code does via `AppDelegate.locateSurface`.
    private func registerWorkspaces(_ workspaces: [Workspace]) -> (app: AppDelegate, window: NSWindow) {
        _ = NSApplication.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(UUID().uuidString)")

        let manager = TabManager()
        manager.tabs = workspaces
        app.registerMainWindow(
            window,
            windowId: UUID(),
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        return (app, window)
    }

    private func waitForCondition(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    func testMovingReviewPanelReinstallsSubscriptionAndTracksSourceInItsOriginalWorkspace() throws {
        let workspaceA = Workspace()
        let workspaceB = Workspace()
        let (_, window) = registerWorkspaces([workspaceA, workspaceB])
        defer { window.orderOut(nil) }

        let sourceId = try XCTUnwrap(workspaceA.focusedPanelId)
        let reviewPanel = try XCTUnwrap(workspaceA.newReviewSplit(from: sourceId, orientation: .horizontal))
        XCTAssertNotNil(workspaceA.panelSubscriptions[reviewPanel.id], "Sanity: creation installs a subscription on the source workspace")

        let detached = try XCTUnwrap(workspaceA.detachSurface(panelId: reviewPanel.id))
        let destinationPane = try XCTUnwrap(workspaceB.bonsplitController.allPaneIds.first)
        XCTAssertEqual(
            workspaceB.attachDetachedSurface(detached, inPane: destinationPane, focus: false),
            reviewPanel.id
        )

        XCTAssertEqual(reviewPanel.workspaceId, workspaceB.id, "Moved review panel must adopt the destination workspace id")
        XCTAssertNotNil(
            workspaceB.panelSubscriptions[reviewPanel.id],
            "Moved review panel must get a fresh lifecycle subscription reinstalled on its new workspace"
        )

        // The source terminal stayed behind in workspace A. The reinstalled subscription must
        // keep watching A's `$panelAgentPresence`, not B's -- otherwise the review panel would
        // never auto-refresh again after the move (M13).
        workspaceA.updatePanelAgentState(panelId: sourceId, state: .working)
        XCTAssertTrue(waitForCondition { workspaceA.panelAgentStates[sourceId] == .working })
        let previousRefreshedAt = reviewPanel.lastRefreshedAt
        workspaceA.updatePanelAgentState(panelId: sourceId, state: .idle)
        XCTAssertTrue(
            waitForCondition {
                reviewPanel.isRefreshing || reviewPanel.lastRefreshedAt != previousRefreshedAt
            },
            "Expected the review panel to start refreshing once its source terminal (still in workspace A) goes idle"
        )
    }

    func testMovingMarkdownPanelUpdatesItsWorkspaceId() throws {
        let workspaceA = Workspace()
        let workspaceB = Workspace()
        _ = registerWorkspaces([workspaceA, workspaceB])

        let sourceId = try XCTUnwrap(workspaceA.focusedPanelId)
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("m13-markdown-transfer-\(UUID().uuidString).md")
        try Data("# M13 regression".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let markdownPanel = try XCTUnwrap(
            workspaceA.newMarkdownSplit(from: sourceId, orientation: .horizontal, filePath: tempFile.path)
        )
        XCTAssertEqual(markdownPanel.workspaceId, workspaceA.id)

        let detached = try XCTUnwrap(workspaceA.detachSurface(panelId: markdownPanel.id))
        let destinationPane = try XCTUnwrap(workspaceB.bonsplitController.allPaneIds.first)
        XCTAssertEqual(
            workspaceB.attachDetachedSurface(detached, inPane: destinationPane, focus: false),
            markdownPanel.id
        )

        XCTAssertEqual(markdownPanel.workspaceId, workspaceB.id, "Moved markdown panel must adopt the destination workspace id")
        XCTAssertNotNil(
            workspaceB.panelSubscriptions[markdownPanel.id],
            "Moved markdown panel must get its title subscription reinstalled on its new workspace"
        )
    }
}


@MainActor
final class SidebarWorkspaceShortcutHintMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SidebarWorkspaceShortcutHintMetrics.resetCacheForTesting()
    }

    override func tearDown() {
        SidebarWorkspaceShortcutHintMetrics.resetCacheForTesting()
        super.tearDown()
    }

    func testHintWidthCachesRepeatedMeasurements() {
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 0)

        let first = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘1")
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 1)

        let second = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘1")
        XCTAssertEqual(second, first)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 1)

        _ = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘2")
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 2)
    }

    func testSlotWidthAppliesMinimumAndDebugInset() {
        let nilLabelWidth = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: nil, debugXOffset: 999)
        XCTAssertEqual(nilLabelWidth, 28)

        let base = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: "⌘1", debugXOffset: 0)
        let widened = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: "⌘1", debugXOffset: 10)
        XCTAssertGreaterThan(widened, base)
    }
}

@MainActor
final class FocusTransitionCoordinatorTests: XCTestCase {
    func testStaleWorkspaceCompletionCannotOverrideNewestOwner() {
        let coordinator = FocusTransitionCoordinator()
        let firstOwner = makeOwner(intent: .terminal(.surface))
        let newestOwner = makeOwner(intent: .browser(.addressBar))

        let staleRequest = coordinator.beginTransition(
            to: firstOwner,
            reason: .workspaceSelection
        )
        let newestRequest = coordinator.beginTransition(
            to: newestOwner,
            reason: .workspaceSelection
        )

        XCTAssertTrue(coordinator.completeTransition(newestRequest))
        XCTAssertEqual(coordinator.committedOwner, newestOwner)
        XCTAssertFalse(
            coordinator.completeTransition(staleRequest),
            "A completion from an older workspace generation must be rejected"
        )
        XCTAssertEqual(coordinator.committedOwner, newestOwner)
    }

    func testStaleSplitReassertCannotOverrideNewerExplicitWorkspaceOwner() {
        let coordinator = FocusTransitionCoordinator()
        let preservedSplitOwner = makeOwner(intent: .terminal(.surface))
        let explicitWorkspaceOwner = makeOwner(intent: .terminal(.findField))

        let staleSplitRequest = coordinator.beginTransition(
            to: preservedSplitOwner,
            reason: .nonFocusSplit
        )
        let explicitWorkspaceRequest = coordinator.beginTransition(
            to: explicitWorkspaceOwner,
            reason: .workspaceSelection
        )

        XCTAssertTrue(coordinator.completeTransition(explicitWorkspaceRequest))
        XCTAssertFalse(
            coordinator.completeTransition(staleSplitRequest),
            "A delayed non-focus split reassert must not replace newer explicit focus"
        )
        XCTAssertEqual(coordinator.committedOwner, explicitWorkspaceOwner)
        XCTAssertEqual(coordinator.newestRequest, explicitWorkspaceRequest)
    }

    private func makeOwner(intent: PanelFocusIntent) -> FocusTransitionCoordinator.Owner {
        FocusTransitionCoordinator.Owner(
            workspaceID: UUID(),
            panelID: UUID(),
            intent: intent
        )
    }
}
