import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine

enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return String(localized: "workspace.placement.top", defaultValue: "Top")
        case .afterCurrent:
            return String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")
        case .end:
            return String(localized: "workspace.placement.end", defaultValue: "End")
        }
    }

    var description: String {
        switch self {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum LastSurfaceCloseShortcutSettings {
    static let key = "closeWorkspaceOnLastSurfaceShortcut"
    // Keep the legacy stored meaning so existing values still map to the same
    // behavior. The default is flipped to preserve current Cmd+W behavior.
    static let defaultValue = true

    static func closesWorkspace(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

struct SidebarWorkspaceAuxiliaryDetailVisibility: Equatable {
    let showsMetadata: Bool
    let showsLog: Bool
    let showsProgress: Bool
    let showsBranchDirectory: Bool
    let showsPullRequests: Bool
    let showsPorts: Bool
}

enum SidebarActiveTabIndicatorStyle: String, CaseIterable, Identifiable {
    case leftRail
    case solidFill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftRail:
            return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill:
            return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }
}

enum SidebarActiveTabIndicatorSettings {
    static let styleKey = "sidebarActiveTabIndicatorStyle"
    static let defaultStyle: SidebarActiveTabIndicatorStyle = .leftRail

    static func resolvedStyle(rawValue: String?) -> SidebarActiveTabIndicatorStyle {
        guard let rawValue else { return defaultStyle }
        if let style = SidebarActiveTabIndicatorStyle(rawValue: rawValue) {
            return style
        }

        // Legacy values from earlier iterations map to the closest modern option.
        switch rawValue {
        case "rail":
            return .leftRail
        case "border", "wash", "lift", "typography", "washRail", "blueWashColorRail":
            return .solidFill
        default:
            return defaultStyle
        }
    }

    static func current(defaults: UserDefaults = .standard) -> SidebarActiveTabIndicatorStyle {
        resolvedStyle(rawValue: defaults.string(forKey: styleKey))
    }
}

enum WorkspacePlacementSettings {
    static let placementKey = "newWorkspacePlacement"
    static let defaultPlacement: NewWorkspacePlacement = .afterCurrent

    static func current(defaults: UserDefaults = .standard) -> NewWorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = NewWorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    static func insertionIndex(
        placement: NewWorkspacePlacement,
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch placement {
        case .top:
            // Keep pinned workspaces grouped at the top by inserting ahead of unpinned items.
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}

struct WorkspaceTabColorEntry: Equatable, Identifiable {
    let name: String
    let hex: String

    var id: String { name }
}

enum WorkspaceTabColorSettings {
    static let paletteKey = "workspaceTabColor.colors"

    private static let legacyDefaultOverridesKey = "workspaceTabColor.defaultOverrides"
    private static let legacyCustomColorsKey = "workspaceTabColor.customColors"

    private static let originalPRPalette: [WorkspaceTabColorEntry] = [
        WorkspaceTabColorEntry(name: "Red", hex: "#C0392B"),
        WorkspaceTabColorEntry(name: "Crimson", hex: "#922B21"),
        WorkspaceTabColorEntry(name: "Orange", hex: "#A04000"),
        WorkspaceTabColorEntry(name: "Amber", hex: "#7D6608"),
        WorkspaceTabColorEntry(name: "Olive", hex: "#4A5C18"),
        WorkspaceTabColorEntry(name: "Green", hex: "#196F3D"),
        WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
        WorkspaceTabColorEntry(name: "Aqua", hex: "#0E6B8C"),
        WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
        WorkspaceTabColorEntry(name: "Navy", hex: "#1A5276"),
        WorkspaceTabColorEntry(name: "Indigo", hex: "#283593"),
        WorkspaceTabColorEntry(name: "Purple", hex: "#6A1B9A"),
        WorkspaceTabColorEntry(name: "Magenta", hex: "#AD1457"),
        WorkspaceTabColorEntry(name: "Rose", hex: "#880E4F"),
        WorkspaceTabColorEntry(name: "Brown", hex: "#7B3F00"),
        WorkspaceTabColorEntry(name: "Charcoal", hex: "#3E4B5E"),
    ]

    static var defaultPalette: [WorkspaceTabColorEntry] {
        originalPRPalette
    }

    static func palette(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let paletteMap = effectivePaletteMap(defaults: defaults)
        let builtInOrder = defaultPalette.compactMap { entry -> WorkspaceTabColorEntry? in
            guard let hex = paletteMap[entry.name] else { return nil }
            return WorkspaceTabColorEntry(name: entry.name, hex: hex)
        }
        let builtInNames = Set(defaultPalette.map(\.name))
        let customEntries = paletteMap
            .filter { !builtInNames.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { WorkspaceTabColorEntry(name: $0.key, hex: $0.value) }
        return builtInOrder + customEntries
    }

    static func customPaletteEntries(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let builtInNames = Set(defaultPalette.map(\.name))
        return palette(defaults: defaults).filter { !builtInNames.contains($0.name) }
    }

    static func defaultColorHex(named name: String) -> String? {
        defaultPalette.first(where: { $0.name == name })?.hex
    }

    static func currentColorHex(named name: String, defaults: UserDefaults = .standard) -> String? {
        effectivePaletteMap(defaults: defaults)[name]
    }

    static func setColor(named name: String, hex: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name),
              let normalizedHex = normalizedHex(hex) else { return }

        var palette = editablePaletteMap(defaults: defaults)
        palette[normalizedName] = normalizedHex
        persistPaletteMap(palette, defaults: defaults)
    }

    static func removeColor(named name: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name) else { return }
        var palette = editablePaletteMap(defaults: defaults)
        palette.removeValue(forKey: normalizedName)
        persistPaletteMap(palette, defaults: defaults)
    }

    static func persistPaletteMap(_ rawPalette: [String: String], defaults: UserDefaults = .standard) {
        let normalizedPalette = normalizedPaletteMap(rawPalette)
        if normalizedPalette == defaultPaletteMap {
            defaults.removeObject(forKey: paletteKey)
        } else {
            defaults.set(normalizedPalette, forKey: paletteKey)
        }
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    static func backupPaletteMap(defaults: UserDefaults = .standard) -> [String: String]? {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        return legacyPaletteMap(defaults: defaults)
    }

    static func resolvedPaletteMap(defaults: UserDefaults = .standard) -> [String: String] {
        effectivePaletteMap(defaults: defaults)
    }

    static func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) -> String? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var palette = editablePaletteMap(defaults: defaults)
        if palette.contains(where: { $0.value == normalized }) {
            return normalized
        }

        palette[nextCustomColorName(existingNames: Set(palette.keys))] = normalized
        persistPaletteMap(palette, defaults: defaults)
        return normalized
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: paletteKey)
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    static func displayColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> Color? {
        guard let color = displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: forceBright) else {
            return nil
        }
        return Color(nsColor: color)
    }

    static func displayNSColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        guard let normalized = normalizedHex(hex),
              let baseColor = NSColor(hex: normalized) else {
            return nil
        }

        if forceBright || colorScheme == .dark {
            return brightenedForDarkAppearance(baseColor)
        }
        return baseColor
    }

    private static func effectivePaletteMap(defaults: UserDefaults) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    private static func editablePaletteMap(defaults: UserDefaults) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    private static func storedPaletteMap(defaults: UserDefaults) -> [String: String]? {
        guard let raw = defaults.dictionary(forKey: paletteKey) as? [String: String] else { return nil }
        return normalizedPaletteMap(raw)
    }

    private static func legacyPaletteMap(defaults: UserDefaults) -> [String: String]? {
        let hasLegacyOverrides = defaults.object(forKey: legacyDefaultOverridesKey) != nil
        let hasLegacyCustomColors = defaults.object(forKey: legacyCustomColorsKey) != nil
        guard hasLegacyOverrides || hasLegacyCustomColors else { return nil }

        var palette = defaultPaletteMap

        if let rawOverrides = defaults.dictionary(forKey: legacyDefaultOverridesKey) as? [String: String] {
            let validNames = Set(defaultPalette.map(\.name))
            for (name, hex) in rawOverrides {
                guard validNames.contains(name),
                      let normalized = normalizedHex(hex) else { continue }
                palette[name] = normalized
            }
        }

        if let rawCustomColors = defaults.array(forKey: legacyCustomColorsKey) as? [String] {
            var index = 1
            var seenCustomHexes: Set<String> = []
            for rawHex in rawCustomColors {
                guard let normalized = normalizedHex(rawHex),
                      seenCustomHexes.insert(normalized).inserted else { continue }
                let name = nextCustomColorName(
                    existingNames: Set(palette.keys),
                    startingAt: index
                )
                palette[name] = normalized
                index += 1
            }
        }

        return palette
    }

    private static func normalizedPaletteMap(_ rawPalette: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawName, rawHex) in rawPalette {
            guard let name = normalizedColorName(rawName),
                  let hex = normalizedHex(rawHex) else { continue }
            normalized[name] = hex
        }
        return normalized
    }

    private static var defaultPaletteMap: [String: String] {
        Dictionary(uniqueKeysWithValues: defaultPalette.map { ($0.name, $0.hex) })
    }

    private static func normalizedColorName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nextCustomColorName(
        existingNames: Set<String>,
        startingAt initialIndex: Int = 1
    ) -> String {
        var index = max(1, initialIndex)
        while true {
            let candidate = "Custom \(index)"
            if !existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            index += 1
        }
    }

    private static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}

struct RecentlyClosedBrowserStack {
    private(set) var entries: [ClosedBrowserPanelRestoreSnapshot] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func push(_ snapshot: ClosedBrowserPanelRestoreSnapshot) {
        entries.append(snapshot)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func pop() -> ClosedBrowserPanelRestoreSnapshot? {
        entries.popLast()
    }
}

@MainActor
class TabManager: ObservableObject {
    struct WorkspaceGitProbeKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    /// Thin owned instance of the stateless git/GitHub CLI probing library (GitMetadataProber.swift).
    /// Its API is invoked as static calls (`GitMetadataProber.foo(...)`); this instance exists as
    /// TabManager's ownership point for that responsibility.
    let gitMetadataProber = GitMetadataProber()
    let focusTransitionCoordinator = FocusTransitionCoordinator()

    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?

    @Published var tabs: [Workspace] = []
    @Published var isWorkspaceCycleHot: Bool = false
    @Published private(set) var pendingBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var debugPinnedWorkspaceLoadIds: Set<UUID> = []

    /// Global monotonically increasing counter for PROGRAMA_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    static var nextPortOrdinal: Int = 0
    static let initialWorkspaceGitProbeDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0, 6.0, 10.0]
    static let workspaceGitMetadataPollInterval: TimeInterval = 30
    static let selectedWorkspaceGitMetadataPollInterval: TimeInterval = 5
    @Published var selectedTabId: UUID? {
        willSet {
#if DEBUG
            guard newValue != selectedTabId else {
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugPreparedWorkspaceSwitchTarget = nil
                return
            }

            if debugPreparedWorkspaceSwitchTarget == newValue {
                debugPreparedWorkspaceSwitchTarget = nil
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
            } else {
                let trigger = (debugPendingWorkspaceSwitchTarget == newValue
                    ? debugPendingWorkspaceSwitchTrigger
                    : nil) ?? "direct"
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugBeginWorkspaceSwitch(
                    trigger: trigger,
                    from: selectedTabId,
                    to: newValue
                )
            }
#endif
        }
        didSet {
            guard selectedTabId != oldValue else { return }
            let previousTabId = oldValue
            if let previousTabId,
               let previousPanelId = focusedPanelId(for: previousTabId) {
                lastFocusedPanelByTab[previousTabId] = previousPanelId
            }
            if !isNavigatingHistory, let selectedTabId {
                recordTabInHistory(selectedTabId)
            }
            let focusTransitionRequest = selectedTabId.flatMap {
                beginWorkspaceSelectionFocusTransition(workspaceId: $0)
            }
#if DEBUG
            let switchId = debugWorkspaceSwitchId
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            dlog(
                "ws.select.didSet id=\(switchId) from=\(Self.debugShortWorkspaceId(previousTabId)) " +
                "to=\(Self.debugShortWorkspaceId(selectedTabId)) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
            selectionSideEffectsGeneration &+= 1
            let generation = selectionSideEffectsGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionSideEffectsGeneration == generation else { return }
                if let focusTransitionRequest {
                    guard self.focusTransitionCoordinator.completeTransition(focusTransitionRequest) else {
                        return
                    }
                    self.focusSelectedTabPanel(
                        previousTabId: previousTabId,
                        requestedPanelId: focusTransitionRequest.owner.panelID
                    )
                } else {
                    self.focusSelectedTabPanel(previousTabId: previousTabId)
                }
                self.updateWindowTitleForSelectedTab()
                if let selectedTabId = self.selectedTabId {
                    self.dismissFocusedPanelNotificationIfActive(tabId: selectedTabId)
                }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.select.asyncDone id=\(self.debugWorkspaceSwitchId) dt=\(Self.debugMsText(dtMs)) " +
                    "selected=\(Self.debugShortWorkspaceId(self.selectedTabId))"
                )
#endif
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    var lastFocusedPanelByTab: [UUID: UUID] = [:]
    struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }
    var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    var recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)
    /// Issue #140: closing a terminal stages it here for a 5s undo window (Cmd+Shift+T) instead
    /// of tearing it down immediately. Owned by TabManager -- the single reachable instance from
    /// every reopen call site (AppDelegate shortcut dispatch, ProgramaApp menu command,
    /// ContentView) and every terminal-close call site (Workspace's confirm-close delegate,
    /// `closeRuntimeSurfaceWithConfirmation`, the v2 socket close handler).
    let closedTerminalUndoStore = ClosedTerminalUndoStore()
    private let initialWorkspaceGitProbeQueue = DispatchQueue(
        label: "com.cmux.initial-workspace-git-probe",
        qos: .utility
    )
    var workspaceGitProbeGenerationByKey: [WorkspaceGitProbeKey: UUID] = [:]
    var workspaceGitProbeTimersByKey: [WorkspaceGitProbeKey: [DispatchSourceTimer]] = [:]
    var workspaceGitTrackedDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]

    // Recent tab history for back/forward navigation (like browser history)
    var tabHistory: [UUID] = []
    var historyIndex: Int = -1
    var isNavigatingHistory = false
    private let maxHistorySize = 50
    var selectionSideEffectsGeneration: UInt64 = 0
    private var workspaceCycleGeneration: UInt64 = 0
    var workspaceCycleCooldownTask: Task<Void, Never>?
    var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?
    var sidebarSelectedWorkspaceIds: Set<UUID> = []
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    private struct WorkspaceCreationTabSnapshot {
        let id: UUID
        let isPinned: Bool

        @MainActor
        init(workspace: Workspace) {
            self.id = workspace.id
            self.isPinned = workspace.isPinned
        }
    }

    private struct WorkspaceCreationSnapshot {
        let tabs: [WorkspaceCreationTabSnapshot]
        let selectedTabId: UUID?
        let selectedTabWasPinned: Bool
        let preferredWorkingDirectory: String?
        let inheritedTerminalFontPoints: Float?
    }
    var agentPIDSweepTimer: DispatchSourceTimer?
    var workspaceGitMetadataPollTimer: DispatchSourceTimer?
    var selectedWorkspaceGitMetadataPollTimer: DispatchSourceTimer?
#if DEBUG
    private var debugWorkspaceSwitchCounter: UInt64 = 0
    private var debugWorkspaceSwitchId: UInt64 = 0
    private var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
    private var debugPendingWorkspaceSwitchTrigger: String?
    private var debugPendingWorkspaceSwitchTarget: UUID?
    private var debugPreparedWorkspaceSwitchTarget: UUID?
#endif

#if DEBUG
    // Widened from `private` to `internal` (default access) so TabManager+UITestHarness.swift,
    // which owns the setup functions that mutate this state, can see it across files.
    var didSetupSplitCloseRightUITest = false
    var didSetupUITestFocusShortcuts = false
    var didSetupChildExitSplitUITest = false
    var didSetupChildExitKeyboardUITest = false
    var uiTestCancellables = Set<AnyCancellable>()
#endif

    init(initialWorkingDirectory: String? = nil) {
        addWorkspace(workingDirectory: initialWorkingDirectory)
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
                enqueuePanelTitleUpdate(tabId: tabId, panelId: surfaceId, title: title)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                dismissPanelNotificationOnFocusIfActive(tabId: tabId, panelId: surfaceId)
            }
        })

        startAgentPIDSweepTimer()
        startWorkspaceGitMetadataPollTimer()
        startSelectedWorkspaceGitMetadataPollTimer()
#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
        setupChildExitSplitUITestIfNeeded()
        setupChildExitKeyboardUITestIfNeeded()
#endif
    }

    deinit {
        workspaceCycleCooldownTask?.cancel()
        agentPIDSweepTimer?.cancel()
        workspaceGitMetadataPollTimer?.cancel()
        selectedWorkspaceGitMetadataPollTimer?.cancel()
    }

    /// Wires both the browser-restore stack and the terminal close-undo callback for `workspace`.
    /// Kept as one pair of functions (rather than a second wire/unwire call site to remember) so
    /// every workspace-lifecycle call site that manages one automatically manages the other.
    func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = { [weak self] snapshot in
            self?.recentlyClosedBrowsers.push(snapshot)
        }
        workspace.onTerminalCloseStagedForUndo = { [weak self, weak workspace] transfer, paneId, index in
            guard let self, let workspace else { return }
            self.stageDetachedTerminalTransferForUndo(
                transfer,
                originalWorkspaceId: workspace.id,
                originalPaneId: paneId,
                originalIndex: index
            )
        }
    }

    func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = nil
        workspace.onTerminalCloseStagedForUndo = nil
    }

    /// Detaches the live terminal panel at `panelId` (same process-alive primitive used for
    /// cross-pane/window tab drag) and stages it for undo instead of closing it immediately. Used
    /// by call sites that are NOT already inside a `bonsplitController.closeTab` call (socket
    /// closes, runtime-close-with-confirmation) -- the interactive tab-close-button/Cmd+W path is
    /// staged separately from inside `Workspace.splitTabBar(_:shouldCloseTab:inPane:)` because
    /// that delegate is already invoked from within a `closeTab` call, and re-entering it via
    /// `detachSurface` (which calls `closeTab` itself) would be unsafe reentrancy.
    ///
    /// Returns false when staging isn't possible (non-terminal panel, a drag-detach already in
    /// flight for this workspace, this is the workspace's only remaining panel, or `detachSurface`
    /// itself declines) -- callers should fall back to a normal close in that case.
    @discardableResult
    func stageTerminalPanelCloseForUndo(in workspace: Workspace, panelId: UUID) -> Bool {
        guard workspace.terminalPanel(for: panelId) != nil else { return false }
        guard !workspace.isDetachingCloseTransaction else { return false }
        // Mirrors `Workspace.markTerminalCloseForUndoStagingIfEligible`'s guard: staging routes
        // through `detachSurface`, which marks the close as a detach. `didCloseTab`'s
        // `panels.isEmpty` branch skips replacement-terminal creation for detaches (correct for
        // real drag-detaches, which intentionally leave a transient empty workspace) but closing
        // a workspace's only remaining panel is an ordinary close and must still get a
        // replacement surface. Decline staging here so the caller falls back to a normal
        // `closePanel`, which isn't marked as detaching.
        guard workspace.panels.count > 1 else { return false }
        let originalPaneId = workspace.paneId(forPanelId: panelId)
        let originalIndex = workspace.indexInPane(forPanelId: panelId)
        guard let transfer = workspace.detachSurface(panelId: panelId) else { return false }

        stageDetachedTerminalTransferForUndo(
            transfer,
            originalWorkspaceId: workspace.id,
            originalPaneId: originalPaneId,
            originalIndex: originalIndex
        )
        return true
    }

    private func stageDetachedTerminalTransferForUndo(
        _ transfer: Workspace.DetachedSurfaceTransfer,
        originalWorkspaceId: UUID,
        originalPaneId: PaneID?,
        originalIndex: Int?
    ) {
        closedTerminalUndoStore.stage(
            restore: { [weak self] in
                self?.restoreDetachedTerminalTransfer(
                    transfer,
                    originalWorkspaceId: originalWorkspaceId,
                    originalPaneId: originalPaneId,
                    originalIndex: originalIndex
                )
            },
            finalize: {
                // Mirrors Workspace+Bonsplit.swift's `didCloseTab` non-detaching teardown: release
                // the SSH control master this transfer was keeping alive (if any), then close the
                // retained panel for real.
                if let cleanupConfiguration = transfer.remoteCleanupConfiguration {
                    Workspace.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
                }
                transfer.panel.close()
            }
        )
    }

    /// Reattaches a previously detached terminal transfer for undo restore. Falls back to the
    /// currently selected workspace's focused pane when the original workspace/pane no longer
    /// exists; drops (closes) the panel if neither is available. Conservative by design -- an
    /// undo restore should never crash or silently do nothing with a live process.
    private func restoreDetachedTerminalTransfer(
        _ transfer: Workspace.DetachedSurfaceTransfer,
        originalWorkspaceId: UUID,
        originalPaneId: PaneID?,
        originalIndex: Int?
    ) {
        func giveUp() {
            if let cleanupConfiguration = transfer.remoteCleanupConfiguration {
                Workspace.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
            }
            transfer.panel.close()
        }

        guard let targetWorkspace = workspace(withId: originalWorkspaceId) ?? selectedWorkspace ?? tabs.first else {
            giveUp()
            return
        }

        let targetPane: PaneID?
        if let originalPaneId, targetWorkspace.bonsplitController.allPaneIds.contains(originalPaneId) {
            targetPane = originalPaneId
        } else {
            targetPane = targetWorkspace.bonsplitController.focusedPaneId ?? targetWorkspace.bonsplitController.allPaneIds.first
        }

        guard let targetPane else {
            giveUp()
            return
        }

        if selectedTabId != targetWorkspace.id {
            selectedTabId = targetWorkspace.id
        }

        let tabCount = targetWorkspace.bonsplitController.tabs(inPane: targetPane).count
        let clampedIndex = originalIndex.map { min(max($0, 0), tabCount) }
        targetWorkspace.attachDetachedSurface(transfer, inPane: targetPane, atIndex: clampedIndex, focus: true)
    }

    /// Canonical workspace lookup by ID. All workspace-by-ID scans across TabManager and its
    /// extensions should go through this helper instead of inlining `tabs.first(where: { $0.id == X })`.
    func workspace(withId id: UUID) -> Workspace? {
        tabs.first(where: { $0.id == id })
    }

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return workspace(withId: selectedTabId)
    }

    // Keep selectedTab as convenience alias
    var selectedTab: Workspace? { selectedWorkspace }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalPanel?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil
            || focusedBrowserPanel?.searchState != nil
            || focusedMarkdownPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    func startSearch() {
        if let panel = selectedTerminalPanel {
            if panel.searchState == nil {
                panel.searchState = TerminalSurface.SearchState()
            }
            NSLog("Find: startSearch workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
            NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
            _ = panel.performBindingAction("start_search")
            return
        }

        if let panel = focusedMarkdownPanel {
            panel.startFind()
            return
        }

        focusedBrowserPanel?.startFind()
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: searchSelection workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:next")
            return
        }

        if let panel = focusedMarkdownPanel {
            panel.findNext()
            return
        }

        focusedBrowserPanel?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:previous")
            return
        }

        if let panel = focusedMarkdownPanel {
            panel.findPrevious()
            return
        }

        focusedBrowserPanel?.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.surface.toggleKeyboardCopyMode()
    }

    func hideFind() {
        if let panel = selectedTerminalPanel {
            panel.searchState = nil
            return
        }

        if let panel = focusedMarkdownPanel {
            panel.hideFind()
            return
        }

        focusedBrowserPanel?.hideFind()
    }

    func makeWorkspaceForCreation(
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: ProgramaSurfaceConfigTemplate?,
        initialTerminalCommand: String?,
        initialTerminalEnvironment: [String: String]
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalEnvironment: initialTerminalEnvironment
        )
    }

    /// Test seam for mutating live workspace state after the creation snapshot is captured.
    func didCaptureWorkspaceCreationSnapshot() {}

#if DEBUG
    private func maybeMutateSelectionDuringWorkspaceCreationForDev(
        snapshot: WorkspaceCreationSnapshot
    ) {
        let env = ProcessInfo.processInfo.environment
        let isEnabled: Bool = {
            if let raw = env["PROGRAMA_DEV_MUTATE_WORKSPACE_SELECTION_DURING_CREATION"] {
                return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
            }
            return UserDefaults.standard.bool(forKey: "programaDevMutateWorkspaceSelectionDuringCreation")
        }()
        guard isEnabled,
              let selectedTabId = snapshot.selectedTabId,
              let targetId = snapshot.tabs.lazy.map(\.id).first(where: { $0 != selectedTabId }),
              tabs.contains(where: { $0.id == targetId }) else {
            return
        }
        dlog(
            "workspace.create.devSelectionMutation from=\(selectedTabId.uuidString.prefix(5)) " +
            "to=\(targetId.uuidString.prefix(5))"
        )
        self.selectedTabId = targetId
    }
#endif

    @discardableResult
    func addWorkspace(
        title: String? = nil,
        workingDirectory overrideWorkingDirectory: String? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: NewWorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true
    ) -> Workspace {
        let sourceWorkspace = selectedWorkspace
        let capturedTabs = tabs
        // Snapshot the selected tab from the pinned workspace instead of rereading the
        // @Published selectedTabId storage after the inheritance helpers. The arm64 Nightly
        // Cmd+N crash is in PublishedSubject.value.getter on that second getter read.
        let capturedSelectedTabId = sourceWorkspace?.id
        // Keep both the source workspace and the pre-creation workspace array alive for the
        // entire creation path. Release ARC can otherwise drop retains early across the
        // helper/insertion chain, which reintroduces use-after-free crashes in optimized builds.
        return withExtendedLifetime((capturedTabs, sourceWorkspace)) {
            let dir = preferredWorkingDirectoryForNewTab(workspace: sourceWorkspace)
            let font = inheritedTerminalFontPointsForNewWorkspace(workspace: sourceWorkspace)
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: dir,
                inheritedTerminalFontPoints: font
            )
            didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            let explicitWorkingDirectory = normalizedWorkingDirectory(overrideWorkingDirectory)
            let workingDirectory = explicitWorkingDirectory ?? snapshot.preferredWorkingDirectory
            var inheritedConfig = workspaceCreationConfigTemplate(
                inheritedTerminalFontPoints: snapshot.inheritedTerminalFontPoints
            )
            if let initialTerminalInput, !initialTerminalInput.isEmpty {
                // Typed into the started shell (TTY input buffering makes it run
                // once the interactive shell is ready), unlike
                // initialTerminalCommand which replaces the shell process and
                // bypasses the user's interactive PATH.
                var config = inheritedConfig ?? ProgramaSurfaceConfigTemplate()
                config.initialInput = initialTerminalInput
                inheritedConfig = config
            }
            // Resolve placement against the pre-creation snapshot before Workspace init
            // boots terminal state. The ssh/new-workspace path can otherwise crash while
            // reading @Published placement state from existing workspaces mid-creation.
            let insertIndex = newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1

            let newWorkspace = makeWorkspaceForCreation(
                title: title ?? "Terminal \(nextTabCount)",
                workingDirectory: workingDirectory,
                portOrdinal: ordinal,
                configTemplate: inheritedConfig,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
            newWorkspace.owningTabManager = self
            if title != nil {
                newWorkspace.setCustomTitle(title)
            }
            wireClosedBrowserTracking(for: newWorkspace)
            if eagerLoadTerminal && !select {
                requestBackgroundWorkspaceLoad(for: newWorkspace.id)
            }
            // Apply insertion to the current live array so post-snapshot closes/reorders
            // are preserved instead of reintroducing stale workspace instances.
            var updatedTabs = tabs
            if insertIndex >= 0 && insertIndex <= updatedTabs.count {
                updatedTabs.insert(newWorkspace, at: insertIndex)
            } else {
                updatedTabs.append(newWorkspace)
            }
            tabs = updatedTabs
            if let terminalPanel = newWorkspace.focusedTerminalPanel {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: newWorkspace.id,
                    panelId: terminalPanel.id
                )
            }
            if eagerLoadTerminal {
                if select {
                    newWorkspace.focusedTerminalPanel?.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
            if select {
#if DEBUG
                debugPrimeWorkspaceSwitchTrigger("create", to: newWorkspace.id)
#endif
                selectedTabId = newWorkspace.id
                NotificationCenter.default.post(
                    name: .ghosttyDidFocusTab,
                    object: nil,
                    userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
                )
            }
#if DEBUG
            UITestRecorder.incrementInt("addTabInvocations")
            UITestRecorder.record([
                "tabCount": String(updatedTabs.count),
                "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            ])
#endif
            if autoWelcomeIfNeeded && select && !UserDefaults.standard.bool(forKey: WelcomeSettings.shownKey) {
                if let appDelegate = AppDelegate.shared {
                    appDelegate.sendWelcomeCommandWhenReady(to: newWorkspace, markShownOnSend: true)
                } else {
                    sendWelcomeWhenReady(to: newWorkspace)
                }
            }
            return newWorkspace
        }
    }

    @MainActor
    private func sendWelcomeWhenReady(to workspace: Workspace) {
        if let terminalPanel = workspace.focusedTerminalPanel,
           terminalPanel.surface.surface != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                terminalPanel.sendText("programa welcome\n")
            }
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func finishIfReady() {
            guard !resolved,
                  let terminalPanel = workspace.focusedTerminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            panelsCancellable?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                terminalPanel.sendText("programa welcome\n")
            }
        }

        panelsCancellable = workspace.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in
                    finishIfReady()
                }
            }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == workspace.id else { return }
            Task { @MainActor in
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in
                if let readyObserver, !resolved {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if !resolved {
                    panelsCancellable?.cancel()
                }
            }
        }
    }

    private func scheduleInitialWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String
    ) {
        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: Self.initialWorkspaceGitProbeDelays,
            reason: "initial"
        )
    }

    func scheduleWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        delays: [TimeInterval],
        reason: String
    ) {
        let normalizedDirectory = normalizeDirectory(directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let generation = UUID()
        cancelWorkspaceGitProbeTimers(for: key)
        workspaceGitProbeGenerationByKey[key] = generation

#if DEBUG
        dlog(
            "workspace.gitProbe.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) dir=\(normalizedDirectory) reason=\(reason)"
        )
#endif

        var timers: [DispatchSourceTimer] = []
        for (index, delay) in delays.enumerated() {
            let isLastAttempt = index == delays.count - 1
            let timer = DispatchSource.makeTimerSource(queue: initialWorkspaceGitProbeQueue)
            timer.schedule(deadline: .now() + delay, repeating: .never)
            timer.setEventHandler { [weak self] in
                let snapshot = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: normalizedDirectory)
                Task { @MainActor [weak self] in
                    self?.applyWorkspaceGitMetadataSnapshot(
                        snapshot,
                        generation: generation,
                        probeKey: key,
                        expectedDirectory: normalizedDirectory,
                        isLastAttempt: isLastAttempt
                    )
                }
            }
            timers.append(timer)
            timer.resume()
        }
        workspaceGitProbeTimersByKey[key] = timers
    }

    private func cancelWorkspaceGitProbeTimers(for key: WorkspaceGitProbeKey) {
        guard let timers = workspaceGitProbeTimersByKey.removeValue(forKey: key) else {
            return
        }
        for timer in timers {
            timer.setEventHandler {}
            timer.cancel()
        }
    }

    func clearWorkspaceGitProbe(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeGenerationByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTimers(for: key)
    }

    private func clearWorkspaceGitProbes(workspaceId: UUID) {
        let keys = Set(workspaceGitProbeGenerationByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTimersByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey = workspaceGitTrackedDirectoryByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
    }

    private func applyWorkspaceGitMetadataSnapshot(
        _ snapshot: GitMetadataProber.InitialWorkspaceGitMetadataSnapshot,
        generation: UUID,
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        defer {
            if shouldStopWorkspaceGitMetadataRefresh(snapshot) || isLastAttempt,
               workspaceGitProbeGenerationByKey[probeKey] == generation {
                clearWorkspaceGitProbe(probeKey)
            }
        }

        guard workspaceGitProbeGenerationByKey[probeKey] == generation else { return }
        guard let workspace = workspace(withId: probeKey.workspaceId) else {
            clearWorkspaceGitProbe(probeKey)
            return
        }
        guard workspace.panels[probeKey.panelId] != nil else {
            clearWorkspaceGitProbe(probeKey)
            return
        }

        guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: probeKey.panelId) else {
            clearWorkspaceGitProbe(probeKey)
            return
        }
        if currentDirectory != expectedDirectory {
            clearWorkspaceGitProbe(probeKey)
#if DEBUG
            dlog(
                "workspace.gitProbe.skip workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
                "panel=\(probeKey.panelId.uuidString.prefix(5)) reason=directoryChanged " +
                "expected=\(expectedDirectory) current=\(currentDirectory)"
            )
#endif
            return
        }

        workspace.updatePanelDirectory(panelId: probeKey.panelId, directory: expectedDirectory)

        let resolvedPullRequest: SidebarPullRequestState? = {
            guard case .resolved(let pullRequest) = snapshot.pullRequest else { return nil }
            return pullRequest
        }()
        let resolvedSidebarMetadata = snapshot.branch != nil || resolvedPullRequest != nil
        if resolvedSidebarMetadata {
            workspaceGitTrackedDirectoryByKey[probeKey] = expectedDirectory
        } else if workspaceGitTrackedDirectoryByKey[probeKey] != expectedDirectory {
            workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
        }

        let nextBranch = snapshot.branch
        if let nextBranch {
            workspace.updatePanelGitBranch(
                panelId: probeKey.panelId,
                branch: nextBranch,
                isDirty: snapshot.isDirty
            )
        } else {
            workspace.clearPanelGitBranch(panelId: probeKey.panelId)
        }

        switch snapshot.pullRequest {
        case .resolved(let pullRequest):
            workspace.updatePanelPullRequest(
                panelId: probeKey.panelId,
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                checks: pullRequest.checks
            )
        case .notFound:
            if workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
        case .unsupportedRepository, .transientFailure:
            break
        }

#if DEBUG
        let branchLabel = snapshot.branch ?? "none"
        let prLabel: String = {
            switch snapshot.pullRequest {
            case .unsupportedRepository:
                return "unsupported"
            case .notFound:
                return "none"
            case .transientFailure:
                return "transientFailure"
            case .resolved(let pullRequest):
                let checks = pullRequest.checks?.rawValue ?? "none"
                return "#\(pullRequest.number):\(pullRequest.status.rawValue):\(checks)"
            }
        }()
        dlog(
            "workspace.gitProbe.apply workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
            "panel=\(probeKey.panelId.uuidString.prefix(5)) branch=\(branchLabel) dirty=\(snapshot.isDirty ? 1 : 0) " +
            "pr=\(prLabel)"
        )
#endif
    }

    private func shouldStopWorkspaceGitMetadataRefresh(
        _ snapshot: GitMetadataProber.InitialWorkspaceGitMetadataSnapshot
    ) -> Bool {
        switch snapshot.pullRequest {
        case .transientFailure:
            return false
        case .unsupportedRepository, .notFound, .resolved:
            return true
        }
    }

    func requestBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard !pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            pendingBackgroundWorkspaceLoadIds = pruned
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            debugPinnedWorkspaceLoadIds = retained
        }
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Workspace {
        let workspace = addWorkspace(select: select, eagerLoadTerminal: eagerLoadTerminal)
        // #167 workspace_lifecycle "created" event -- single funnel point for both UI-driven
        // (new tab button, keyboard shortcut) and socket-driven (workspace.create) creation.
        SocketEventBroadcaster.shared.publishWorkspaceLifecycle(kind: "created", workspaceId: workspace.id, title: workspace.title)
        return workspace
    }

    func terminalPanelForWorkspaceConfigInheritanceSource() -> TerminalPanel? {
        terminalPanelForWorkspaceConfigInheritanceSource(workspace: selectedWorkspace)
    }

    /// Build a snapshot using pre-extracted value-type data. The caller is responsible
    /// for obtaining `preferredWorkingDirectory` and `inheritedTerminalFontPoints` through
    /// `self` (where `self.tabs` keeps all Workspace objects alive) so that no local
    /// Workspace references are needed here.
    private func workspaceCreationSnapshotLite(
        currentTabs: [Workspace],
        currentSelectedTabId: UUID?,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) -> WorkspaceCreationSnapshot {
        var tabSnapshots: [WorkspaceCreationTabSnapshot] = []
        tabSnapshots.reserveCapacity(currentTabs.count)
        for workspace in currentTabs {
            // Keep each Workspace alive while copying the tiny value snapshot out of it.
            // The optimized arm64 Nightly build can otherwise over-release during
            // Collection.map, crashing here in swift_release / snapshot creation.
            let snapshot = withExtendedLifetime(workspace) {
                WorkspaceCreationTabSnapshot(workspace: workspace)
            }
            tabSnapshots.append(snapshot)
        }
        let selectedTabSnapshot = currentSelectedTabId.flatMap { selectedTabId in
            tabSnapshots.first(where: { $0.id == selectedTabId })
        }

        return WorkspaceCreationSnapshot(
            tabs: tabSnapshots,
            selectedTabId: currentSelectedTabId,
            selectedTabWasPinned: selectedTabSnapshot?.isPinned ?? false,
            preferredWorkingDirectory: preferredWorkingDirectory,
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
    }

    private func workspaceCreationSnapshot() -> WorkspaceCreationSnapshot {
        workspaceCreationSnapshotLite(
            currentTabs: tabs,
            currentSelectedTabId: selectedTabId,
            preferredWorkingDirectory: preferredWorkingDirectoryForNewTab(),
            inheritedTerminalFontPoints: inheritedTerminalFontPointsForNewWorkspace()
        )
    }

    private func orderedLiveWorkspaceCreationTabs(
        from snapshot: WorkspaceCreationSnapshot
    ) -> [WorkspaceCreationTabSnapshot]? {
        let currentTabs = tabs
        let snapshotTabsById = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
        var orderedTabs: [WorkspaceCreationTabSnapshot] = []
        orderedTabs.reserveCapacity(currentTabs.count)

        for workspace in currentTabs {
            guard let tabSnapshot = snapshotTabsById[workspace.id] else {
#if DEBUG
                dlog(
                    "workspace.create.reentrantSnapshotFallback " +
                    "snapshotCount=\(snapshot.tabs.count) liveCount=\(currentTabs.count)"
                )
#endif
                return nil
            }
            orderedTabs.append(tabSnapshot)
        }

        return orderedTabs
    }

    private func terminalPanelForWorkspaceConfigInheritanceSource(
        workspace: Workspace?
    ) -> TerminalPanel? {
        guard let workspace else { return nil }
        // Prefer cached/published panel state here instead of walking live Bonsplit focus
        // during Cmd+N; rapid workspace creation can observe transient pane/tab selection.
        let panels = workspace.panels
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        appendCandidate(workspace.lastRememberedTerminalPanelForConfigInheritance())
        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        if let livePanel = candidates.first(where: { $0.surface.hasLiveSurface && $0.surface.surface != nil }) {
            return livePanel
        }
        return candidates.first
    }

    private func cachedInheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        guard let workspace else { return nil }
        // New workspace creation only seeds font size into a fresh Swift-owned template.
        // Avoid reading live panel/surface state here; the arm64 Nightly Cmd+N crash path
        // was repeatedly dereferencing pointer-backed terminal objects while preparing the
        // new workspace. The workspace already caches the rooted font lineage we need.
        return withExtendedLifetime(workspace) {
            guard let fontPoints = workspace.lastRememberedTerminalFontPointsForConfigInheritance(),
                  fontPoints > 0 else {
                return nil
            }
            return fontPoints
        }
    }

    private func inheritedTerminalFontPointsForNewWorkspace() -> Float? {
        inheritedTerminalFontPointsForNewWorkspace(workspace: selectedWorkspace)
    }

    private func inheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace)
    }

    private func workspaceCreationConfigTemplate(
        inheritedTerminalFontPoints: Float?
    ) -> ProgramaSurfaceConfigTemplate? {
        guard let inheritedTerminalFontPoints, inheritedTerminalFontPoints > 0 else {
            return nil
        }
        // Rebuild a clean Swift-owned template instead of carrying over any pointer-backed
        // inherited config state from the source workspace.
        var config = ProgramaSurfaceConfigTemplate()
        config.fontSize = inheritedTerminalFontPoints
        return config
    }

    func normalizedWorkingDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let normalized = normalizeDirectory(directory)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    private func newTabInsertIndex(placementOverride: NewWorkspacePlacement? = nil) -> Int {
        newTabInsertIndex(snapshot: workspaceCreationSnapshot(), placementOverride: placementOverride)
    }

    private func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: NewWorkspacePlacement? = nil
    ) -> Int {
        let placement = placementOverride ?? WorkspacePlacementSettings.current()
        let liveTabs = orderedLiveWorkspaceCreationTabs(from: snapshot) ?? snapshot.tabs
        let pinnedCount = liveTabs.reduce(into: 0) { partial, tab in
            if tab.isPinned {
                partial += 1
            }
        }

        switch placement {
        case .top:
            return pinnedCount
        case .end:
            return liveTabs.count
        case .afterCurrent:
            if let selectedTabId = snapshot.selectedTabId,
               let selectedIndex = liveTabs.firstIndex(where: { $0.id == selectedTabId }) {
                return WorkspacePlacementSettings.insertionIndex(
                    placement: placement,
                    selectedIndex: selectedIndex,
                    selectedIsPinned: snapshot.selectedTabWasPinned,
                    pinnedCount: pinnedCount,
                    totalCount: liveTabs.count
                )
            }
            return snapshot.selectedTabWasPinned ? pinnedCount : liveTabs.count
        }
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        preferredWorkingDirectoryForNewTab(workspace: selectedWorkspace)
    }

    private func preferredWorkingDirectoryForNewTab(
        workspace: Workspace?
    ) -> String? {
        guard let workspace else {
            return nil
        }
        // Use cached directory state only; avoiding live focus traversal keeps workspace
        // creation resilient when Bonsplit is in the middle of a rapid Cmd+N churn.
        if let currentDirectory = normalizedWorkingDirectory(workspace.currentDirectory) {
            return currentDirectory
        }

        return workspace.panelDirectories.values.lazy.compactMap { directory in
            self.normalizedWorkingDirectory(directory)
        }.first
    }

    func moveTabToTop(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard index != 0 else { return }
        let tab = tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? 0 : pinnedCount
        tabs.insert(tab, at: insertIndex)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
        let selectedPinned = selectedTabs.filter { $0.isPinned }
        let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
        let remainingPinned = remainingTabs.filter { $0.isPinned }
        let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
        tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
    }

    func moveTabToTopForNotification(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let pinnedCount = tabs.filter { $0.isPinned }.count
        guard index != pinnedCount else { return }
        let tab = tabs[index]
        guard !tab.isPinned else { return }
        tabs.remove(at: index)
        tabs.insert(tab, at: pinnedCount)
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        if tabs.count <= 1 { return true }

        let workspace = tabs[currentIndex]
        let clamped = clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        if currentIndex == clamped { return true }

        tabs.remove(at: currentIndex)
        tabs.insert(workspace, at: clamped)
        return true
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> Bool {
        guard tabs.contains(where: { $0.id == tabId }) else { return false }
        if let beforeId {
            guard let idx = tabs.firstIndex(where: { $0.id == beforeId }) else { return false }
            return reorderWorkspace(tabId: tabId, toIndex: idx)
        }
        if let afterId {
            guard let idx = tabs.firstIndex(where: { $0.id == afterId }) else { return false }
            return reorderWorkspace(tabId: tabId, toIndex: idx + 1)
        }
        return false
    }

    func setCustomTitle(tabId: UUID, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
        // #167 workspace_lifecycle "renamed" event. Deliberately scoped to this explicit-rename
        // entry point (used by both the tab-bar rename UI and workspace.rename), NOT to every
        // automatic shell-title update -- those happen continuously as the user runs commands
        // and would flood subscribers with noise unrelated to an actual rename.
        SocketEventBroadcaster.shared.publishWorkspaceLifecycle(kind: "renamed", workspaceId: tabId, title: tabs[index].title)
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func setCustomDescription(tabId: UUID, description: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomDescription(description)
    }

    func clearCustomDescription(tabId: UUID) {
        setCustomDescription(tabId: tabId, description: nil)
    }

    func setTabColor(tabId: UUID, color: String?) {
        guard let tab = workspace(withId: tabId) else { return }
        tab.setCustomColor(color)
    }

    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
    }

    private func reorderTabForPinnedState(_ tab: Workspace) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    private func clampedReorderIndex(for workspace: Workspace, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        let pinnedCount = tabs.filter { $0.isPinned }.count
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = workspace(withId: tabId) else { return }
        let previousDirectory = gitProbeDirectory(for: tab, panelId: surfaceId)
        let normalized = normalizeDirectory(directory)
        tab.updatePanelDirectory(panelId: surfaceId, directory: normalized)
        let nextDirectory = normalizedWorkingDirectory(normalized)
        if previousDirectory != nextDirectory {
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
        }
    }

    func updateSurfaceGitBranch(
        tabId: UUID,
        surfaceId: UUID,
        branch: String,
        isDirty: Bool
    ) {
        guard let tab = workspace(withId: tabId) else { return }
        let current = tab.panelGitBranches[surfaceId]
        let normalizedBranch = GitMetadataProber.normalizedBranchName(branch) ?? branch
        guard current?.branch != normalizedBranch || current?.isDirty != isDirty else { return }
        tab.updatePanelGitBranch(panelId: surfaceId, branch: normalizedBranch, isDirty: isDirty)
        if let directory = gitProbeDirectory(for: tab, panelId: surfaceId) {
            let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
            workspaceGitTrackedDirectoryByKey[probeKey] = directory
        }
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
    }

    func clearSurfaceGitBranch(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        let hadBranch = tab.panelGitBranches[surfaceId] != nil
        let hadPullRequest = tab.panelPullRequests[surfaceId] != nil
        guard hadBranch || hadPullRequest else { return }
        tab.clearPanelGitBranch(panelId: surfaceId)
        tab.clearPanelPullRequest(panelId: surfaceId)
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchCleared"
        )
    }

    /// Updates the shell-activity state for a surface.
    ///
    /// - Returns: `true` if the update was applied (workspace and panel both exist and
    ///   state changed), `false` otherwise. Callers that deduplicate reports MUST only
    ///   record the state in their dedup dict when this returns `true`.
    @discardableResult
    func updateSurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: Workspace.PanelShellActivityState
    ) -> Bool {
        guard let tab = workspace(withId: tabId) else { return false }
        return tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
    }

    /// Reports a lifecycle-hook-driven agent activity state (working/blocked/idle) for a
    /// surface (issue #164, v1 hook tier). See AgentActivityState.swift.
    ///
    /// - Returns: `true` if the workspace/panel exist and the state was applied.
    @discardableResult
    func updateSurfaceAgentState(
        tabId: UUID,
        surfaceId: UUID,
        state: AgentActivityState,
        source: AgentStateSource = .hooks
    ) -> Bool {
        guard let tab = workspace(withId: tabId), tab.panels[surfaceId] != nil else { return false }
        tab.updatePanelAgentState(panelId: surfaceId, state: state, source: source)
        return true
    }

    /// Clears a previously reported agent activity state for a surface (e.g. on hook
    /// session-end). No-ops if the workspace/panel don't exist.
    func clearSurfaceAgentState(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        tab.clearPanelAgentState(panelId: surfaceId)
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    func closeWorkspace(_ workspace: Workspace) {
        // Guard against tearing down a workspace this manager doesn't own (e.g. a
        // stray/external Workspace instance never inserted into `tabs`). Without
        // this check, teardownAllPanels()/teardownRemoteConnection() below would
        // unconditionally mutate whatever workspace was passed in.
        guard tabs.contains(where: { $0.id == workspace.id }) else { return }
        guard tabs.count > 1 else { return }
        clearWorkspaceGitProbes(workspaceId: workspace.id)
        sidebarSelectedWorkspaceIds.remove(workspace.id)

        let closedWorkspaceId = workspace.id
        let closedWorkspaceTitle = workspace.title

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        unwireClosedBrowserTracking(for: workspace)
        workspace.owningTabManager = nil

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)

            if selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }

        // #167 workspace_lifecycle "closed" event -- single funnel point for both UI-driven and
        // socket-driven (workspace.close) closure.
        SocketEventBroadcaster.shared.publishWorkspaceLifecycle(kind: "closed", workspaceId: closedWorkspaceId, title: closedWorkspaceTitle)
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        clearWorkspaceGitProbes(workspaceId: tabId)
        sidebarSelectedWorkspaceIds.remove(tabId)

        let removed = tabs.remove(at: index)
        unwireClosedBrowserTracking(for: removed)
        removed.owningTabManager = nil
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspace.owningTabManager = self
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        if select {
            selectedTabId = workspace.id
        }
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentWorkspace() {
        guard let selectedId = selectedTabId,
              let workspace = workspace(withId: selectedId) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard let selectedId = selectedTabId,
              let tab = workspace(withId: selectedId) else { return }
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        guard let focusedPanelId = shortcutCloseTargetPanelId(in: tab) else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func canCloseOtherTabsInFocusedPane() -> Bool {
        closeOtherTabsInFocusedPanePlan() != nil
    }

    func closeOtherTabsInFocusedPaneWithConfirmation() {
        guard let plan = closeOtherTabsInFocusedPanePlan() else { return }

        let count = plan.panelIds.count
        let titleLines = plan.titles.map { "• \($0)" }.joined(separator: "\n")
        let message = "This is about to close \(count) tab\(count == 1 ? "" : "s") in this pane:\n\(titleLines)"
        guard confirmClose(
            title: "Close other tabs?",
            message: message,
            acceptCmdD: false
        ) else { return }

        for panelId in plan.panelIds {
            _ = plan.workspace.closePanel(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        let sidebarSelectionIds = orderedSidebarSelectedWorkspaceIds()
        if sidebarSelectionIds.count > 1 {
            closeWorkspacesWithConfirmation(sidebarSelectionIds, allowPinned: true)
            return
        }
        guard let selectedId = selectedTabId,
              let workspace = workspace(withId: selectedId) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func canCloseWorkspace(_ workspace: Workspace, allowPinned: Bool = false) -> Bool {
        allowPinned || !workspace.isPinned
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmClose(
                title: String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?"),
                message: String(
                    localized: "dialog.closePinnedWorkspace.message",
                    defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
                ),
                acceptCmdD: tabs.count <= 1
            ) else {
                return false
            }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace)
        return true
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(tabId: UUID) -> Bool {
        guard let workspace = workspace(withId: tabId) else { return false }
        return closeWorkspaceWithConfirmation(workspace)
    }

    func setSidebarSelectedWorkspaceIds(_ workspaceIds: Set<UUID>) {
        let existingIds = Set(tabs.map(\.id))
        sidebarSelectedWorkspaceIds = workspaceIds.intersection(existingIds)
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceWithConfirmation(workspaces[0])
            return
        }

        let plan = closeWorkspacesPlan(for: workspaces)
        guard confirmClose(
            title: plan.title,
            message: plan.message,
            acceptCmdD: plan.acceptCmdD
        ) else { return }

        for workspace in plan.workspaces {
            guard tabs.contains(where: { $0.id == workspace.id }) else { continue }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select", to: workspace.id)
#endif
        selectedTabId = workspace.id
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    private func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        _ = acceptCmdD

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        if NSApp.activationPolicy() == .regular {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct CloseOtherTabsInFocusedPanePlan {
        let workspace: Workspace
        let panelIds: [UUID]
        let titles: [String]
    }

    private struct CloseWorkspacesPlan {
        let workspaces: [Workspace]
        let title: String
        let message: String
        let acceptCmdD: Bool
    }

    private func closeOtherTabsInFocusedPanePlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let workspace = selectedWorkspace else { return nil }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        let tabsInPane = workspace.bonsplitController.tabs(inPane: paneId)
        guard !tabsInPane.isEmpty else { return nil }
        guard let selectedTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id ?? tabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for tab in tabsInPane where tab.id != selectedTabId {
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
            if workspace.isPanelPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(closeOtherTabsDisplayTitle(workspace.panelTitle(panelId: panelId)))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedPanePlan(
            workspace: workspace,
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    private func closeOtherTabsDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return "Untitled Tab"
    }

    private func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Workspace] {
        let targetIds = Set(workspaceIds)
        return tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    private func orderedSidebarSelectedWorkspaceIds() -> [UUID] {
        tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    private func closeWorkspacesPlan(for workspaces: [Workspace]) -> CloseWorkspacesPlan {
        let willCloseWindow = workspaces.count == tabs.count
        let title = willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        let titleLines = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        let message = String(format: format, locale: .current, Int64(workspaces.count), titleLines)
        return CloseWorkspacesPlan(
            workspaces: workspaces,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    private func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

    private func closeWorkspaceIfRunningProcess(_ workspace: Workspace, requiresConfirmation: Bool = true) {
        let willCloseWindow = tabs.count <= 1
        if requiresConfirmation,
           workspaceNeedsConfirmClose(workspace),
           !confirmClose(
               title: String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
               message: String(localized: "dialog.closeWorkspace.message", defaultValue: "This will close the workspace and all of its panels."),
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window: close the window (Cmd+Shift+W behavior).
            if let window {
                window.performClose(nil)
            } else {
                AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    private func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        LastSurfaceCloseShortcutSettings.closesWorkspace() &&
            workspace.panels.count <= 1 &&
            workspace.panels[panelId] != nil
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        guard tab.panels[panelId] != nil else {
#if DEBUG
            dlog(
                "surface.close.shortcut.skip tab=\(tab.id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return
        }

        let bonsplitTabCount = tab.bonsplitController.allPaneIds.reduce(0) { partial, paneId in
            partial + tab.bonsplitController.tabs(inPane: paneId).count
        }
        let panelKind: String = {
            guard let panel = tab.panels[panelId] else { return "missing" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }()
        let closesWorkspaceOnLastSurfaceShortcut = shouldCloseWorkspaceOnLastSurfaceShortcut(tab, panelId: panelId)
#if DEBUG
        dlog(
            "surface.close.shortcut.begin tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) kind=\(panelKind) " +
            "panelCount=\(tab.panels.count) bonsplitTabs=\(bonsplitTabCount) " +
            "closeWorkspaceOnLastSurface=\(closesWorkspaceOnLastSurfaceShortcut ? 1 : 0)"
        )
#endif

        // The last-surface shortcut preference only affects Cmd+W. The tab close button
        // continues to use Workspace's explicit-close path when it closes the last surface.
        if closesWorkspaceOnLastSurfaceShortcut,
           let surfaceId = tab.surfaceIdFromPanelId(panelId) {
            tab.markExplicitClose(surfaceId: surfaceId)
        }
        let closed = tab.closePanel(panelId)
#if DEBUG
        dlog(
            "surface.close.shortcut tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) " +
            "panelsAfterCall=\(tab.panels.count)"
        )
#endif
        // Clear unconditionally, matching closeRuntimeSurfaceWithConfirmation/closeRuntimeSurface:
        // when this is the workspace's last surface, bonsplit's shouldCloseTab delegate escalates
        // to owningTabManager.closeWorkspaceWithConfirmation(...) and returns false here (the panel
        // itself isn't closed via this call), so gating on `closed` would leave the notification
        // for an explicitly-closed surface stuck as unread.
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: panelId)
    }

    private func shortcutCloseTargetPanelId(in workspace: Workspace) -> UUID? {
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.panels[focusedPanelId] != nil {
            return focusedPanelId
        }

        if workspace.panels.count == 1 {
            return workspace.panels.keys.first
        }

        let candidatePane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        if let candidatePane,
           let selectedTabId = workspace.bonsplitController.selectedTab(inPane: candidatePane)?.id
                ?? workspace.bonsplitController.tabs(inPane: candidatePane).first?.id,
           let panelId = workspace.panelIdFromSurfaceId(selectedTabId),
           workspace.panels[panelId] != nil {
            return panelId
        }

        return nil
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    /// Runtime close requests from Ghostty should only ever target the specific surface.
    /// They must not escalate into workspace/window-close semantics for "last tab".
    func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        guard tab.panels[surfaceId] != nil else { return }

        if let terminalPanel = tab.terminalPanel(for: surfaceId),
           tab.panelNeedsConfirmClose(panelId: surfaceId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            guard confirmClose(
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                acceptCmdD: false
            ) else { return }
        }

        if !stageTerminalPanelCloseForUndo(in: tab, panelId: surfaceId) {
            _ = tab.closePanel(surfaceId, force: true)
        }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Runtime close requests from Ghostty without confirmation (e.g. child-exit).
    /// This path must only close the addressed surface and must never close the workspace window.
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        guard tab.panels[surfaceId] != nil else { return }

#if DEBUG
        dlog(
            "surface.close.runtime tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panelsBefore=\(tab.panels.count)"
        )
#endif

        // Keep AppKit first responder in sync with workspace focus before routing the close.
        // If split reparenting caused a temporary model/view mismatch, fallback close logic in
        // Workspace.closePanel uses focused selection to resolve the correct tab deterministically.
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        let closed = tab.closePanel(surfaceId, force: true)
#if DEBUG
        dlog(
            "surface.close.runtime.done tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) panelsAfter=\(tab.panels.count)"
        )
#endif
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        guard tab.panels[surfaceId] != nil else { return }
        let keepsRemoteWorkspaceOpen =
            tab.panels.count <= 1 && tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId)

#if DEBUG
        dlog(
            "surface.close.childExited tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(tab.panels.count) workspaces=\(tabs.count) " +
            "remoteWorkspace=\(tab.isRemoteWorkspace ? 1 : 0) keepRemote=\(keepsRemoteWorkspaceOpen ? 1 : 0)"
        )
#endif

        // Exiting the last SSH surface should demote the workspace back to a local one.
        // Route through Workspace close handling so remote teardown and replacement-panel
        // logic run before TabManager considers removing the workspace itself, including
        // session-end paths where remote configuration was cleared before Ghostty delivered
        // the child-exit callback.
        if keepsRemoteWorkspaceOpen {
            closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
            return
        }

        // Child-exit on the last panel should collapse the workspace, matching explicit close
        // semantics (and close the window when it was the last workspace).
        if tab.panels.count <= 1 {
            if tabs.count <= 1 {
                if let app = AppDelegate.shared {
                    app.notificationStore?.clearNotifications(forTabId: tabId)
                    app.closeMainWindowContainingTabId(tabId)
                } else {
                    // Headless/test fallback when no AppDelegate window context exists.
                    closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(tab)
            }
            return
        }

        closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return workspace.needsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        workspace(withId: tabId)?.title
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for tabId: UUID) -> UUID? {
        workspace(withId: tabId)?.focusedPanelId
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? BrowserPanel
    }

    /// Returns the focused panel if it's a MarkdownPanel, nil otherwise
    var focusedMarkdownPanel: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? MarkdownPanel
    }

    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserPanel?.resetZoom() ?? false
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserPanel?.toggleDeveloperTools() ?? false
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserPanel?.showDeveloperToolsConsole() ?? false
    }

    @discardableResult
    func toggleReactGrabFromCurrentFocus() -> Bool {
        guard let workspace = selectedWorkspace else { return false }

        let snapshots = workspace.panels.values.map { panel in
            ReactGrabShortcutPanelSnapshot(
                id: panel.id,
                panelType: panel.panelType,
                isFocused: panel.id == workspace.focusedPanelId
            )
        }
        guard let route = resolveReactGrabShortcutRoute(panels: snapshots),
              let browserPanel = workspace.browserPanel(for: route.browserPanelId) else {
            return false
        }

        if let returnTerminalPanelId = route.returnTerminalPanelId {
            browserPanel.armReactGrabRoundTrip(returnTo: returnTerminalPanelId)
        } else {
            browserPanel.clearReactGrabRoundTrip(reason: "shortcut.noReturnTarget")
        }

        if workspace.focusedPanelId != browserPanel.id {
            workspace.clearSplitZoom()
            workspace.focusPanel(browserPanel.id)
        }

        let didRequestExplicitWebViewFocus = browserPanel.requestExplicitWebViewFocus()
#if DEBUG
        dlog(
            "reactGrab.pasteback h1.focusRequestResult " +
            "workspace=\(workspace.id.uuidString.prefix(5)) " +
            "browser=\(browserPanel.id.uuidString.prefix(5)) " +
            "return=\(route.returnTerminalPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
            "success=\(didRequestExplicitWebViewFocus ? 1 : 0)"
        )
#endif

        Task { @MainActor [weak browserPanel] in
            guard let browserPanel else { return }
            if route.returnTerminalPanelId != nil {
                await browserPanel.ensureReactGrabActive()
            } else {
                await browserPanel.toggleOrInjectReactGrab()
            }
            if !didRequestExplicitWebViewFocus {
                _ = browserPanel.requestExplicitWebViewFocus()
            }
        }
        return true
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = workspace(withId: selectedTabId),
              let terminalPanel = tab.focusedTerminalPanel else { return }
        terminalPanel.applyWindowBackgroundIfActive()
    }

    private func beginWorkspaceSelectionFocusTransition(
        workspaceId: UUID
    ) -> FocusTransitionCoordinator.Request? {
        guard let workspace = workspace(withId: workspaceId) else { return nil }
        let panelId: UUID
        if let restoredPanelId = lastFocusedPanelByTab[workspaceId],
           workspace.panels[restoredPanelId] != nil {
            panelId = restoredPanelId
        } else if let focusedPanelId = workspace.focusedPanelId,
                  workspace.panels[focusedPanelId] != nil {
            panelId = focusedPanelId
        } else {
            return nil
        }
        guard let panel = workspace.panels[panelId] else { return nil }
        let owner = FocusTransitionCoordinator.Owner(
            workspaceID: workspaceId,
            panelID: panelId,
            intent: panel.preferredFocusIntentForActivation()
        )
        return focusTransitionCoordinator.beginTransition(
            to: owner,
            reason: .workspaceSelection
        )
    }

    private func focusSelectedTabPanel(
        previousTabId: UUID?,
        requestedPanelId: UUID? = nil
    ) {
        guard let selectedTabId,
              let tab = workspace(withId: selectedTabId) else { return }

        let panelId: UUID
        if let requestedPanelId {
            guard tab.panels[requestedPanelId] != nil else { return }
            panelId = requestedPanelId
        } else if let restoredPanelId = lastFocusedPanelByTab[selectedTabId],
           tab.panels[restoredPanelId] != nil {
            panelId = restoredPanelId
        } else if let focusedPanelId = tab.focusedPanelId,
                  tab.panels[focusedPanelId] != nil {
            panelId = focusedPanelId
        } else {
            return
        }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousTabId,
           let previousTab = workspace(withId: previousTabId),
           let previousPanelId = previousTab.focusedPanelId,
           previousTab.panels[previousPanelId] != nil {
            replacePendingWorkspaceUnfocusTarget(
                with: (tabId: previousTabId, panelId: previousPanelId)
            )
        }

        // Route workspace reactivation through the normal focus machinery so panel-local
        // activation intents like browser find-field focus are restored on return.
        tab.focusPanel(panelId)
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        guard let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingTabId: pending.tabId,
            selectedTabId: selectedTabId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
#if DEBUG
            dlog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=selected_again"
            )
#endif
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspacePanel(tabId: pending.tabId, panelId: pending.panelId)
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        } else {
            dlog(
                "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(pending.tabId)) " +
                "panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        }
#endif
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (tabId: UUID, panelId: UUID)) {
        if let current = pendingWorkspaceUnfocusTarget,
           current.tabId == next.tabId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingTabId: current.tabId,
                selectedTabId: selectedTabId
            ) {
                unfocusWorkspacePanel(tabId: current.tabId, panelId: current.panelId)
#if DEBUG
                dlog(
                    "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced_selected"
                )
#endif
            }
        }

        pendingWorkspaceUnfocusTarget = next
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        } else {
            dlog(
                "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        }
#endif
    }

    private func unfocusWorkspacePanel(tabId: UUID, panelId: UUID) {
        guard let tab = workspace(withId: tabId),
              let panel = tab.panels[panelId] else { return }
        panel.unfocus()
    }

    static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        selectedTabId != pendingTabId
    }

    private func dismissFocusedPanelNotificationIfActive(tabId: UUID) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let panelId = focusedPanelId(for: tabId) else { return }
        dismissPanelNotificationOnFocusIfActive(tabId: tabId, panelId: panelId)
    }

    private func dismissPanelNotificationOnFocusIfActive(tabId: UUID, panelId: UUID) {
        guard selectedTabId == tabId else { return }
        guard !suppressFocusFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        _ = dismissNotificationOnDirectInteraction(tabId: tabId, surfaceId: panelId)
    }

    @discardableResult
    func dismissNotificationOnDirectInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        guard selectedTabId == tabId else { return false }
        guard AppFocusState.isAppActive() else { return false }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return false }
        let hasUnreadNotification = notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId)
        let hasFocusedIndicator = notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: surfaceId)
        guard hasUnreadNotification || hasFocusedIndicator else { return false }
        if hasUnreadNotification {
            notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
        }
        notificationStore.clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        if let panelId = surfaceId,
           let tab = workspace(withId: tabId) {
            tab.triggerNotificationDismissFlash(panelId: panelId)
        }
        return true
    }

    private func enqueuePanelTitleUpdate(tabId: UUID, panelId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = PanelTitleUpdateKey(tabId: tabId, panelId: panelId)
        pendingPanelTitleUpdates[key] = trimmed
        panelTitleUpdateCoalescer.signal { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    private func flushPendingPanelTitleUpdates() {
        guard !pendingPanelTitleUpdates.isEmpty else { return }
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: title)
        }
    }

    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = workspace(withId: tabId) else { return }
        let didChange = tab.updatePanelTitle(panelId: panelId, title: title)
        guard didChange else { return }

        // Update window title if this is the selected tab and focused panel
        if selectedTabId == tabId && tab.focusedPanelId == panelId {
            updateWindowTitle(for: tab)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = workspace(withId: selectedTabId) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Workspace?) {
        let title = windowTitle(for: tab)
        guard let targetWindow = window else { return }
        targetWindow.title = title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        guard let tab else { return "Programa" }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "Programa" : trimmedDirectory
    }

    func focusTab(_ tabId: UUID, surfaceId: UUID? = nil, suppressFlash: Bool = false) {
        guard let tab = workspace(withId: tabId) else { return }
        if let surfaceId, tab.panels[surfaceId] != nil {
            // Keep selected-surface intent stable across selectedTabId didSet async restore.
            lastFocusedPanelByTab[tabId] = surfaceId
        }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("focus", to: tabId)
#endif
        selectedTabId = tabId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.unhide(nil)
            if let app = AppDelegate.shared,
               let windowId = app.windowId(for: self),
               let window = app.mainWindow(for: windowId) {
                window.makeKeyAndOrderFront(nil)
            } else if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }

        if let surfaceId {
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: surfaceId)
            } else {
                tab.focusPanel(surfaceId)
            }
        }
    }

    @discardableResult
    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) -> Bool {
        guard let tab = workspace(withId: tabId) else {
#if DEBUG
            dlog("notification.focus.fail tab=\(tabId.uuidString.prefix(5)) reason=missingTab")
#endif
            return false
        }
        if let surfaceId, tab.panels[surfaceId] == nil {
#if DEBUG
            dlog(
                "notification.focus.fail tab=\(tabId.uuidString.prefix(5)) " +
                "panel=\(surfaceId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return false
        }
        let desiredPanelId = surfaceId ?? tab.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredPanelId)
        }
#endif
        // Jump-to-unread should reveal the destination pane instead of keeping an old split-zoom
        // state active around it.
        tab.clearSplitZoom()
        suppressFocusFlash = true
        focusTab(tabId, surfaceId: desiredPanelId, suppressFlash: true)
        suppressFocusFlash = false

        let targetPanelId = desiredPanelId ?? tab.focusedPanelId

        // This focus is applied directly above and does not go through a `selectedTabId`
        // change (the tab is normally already selected), so it never captures a fresh
        // FocusTransitionCoordinator request of its own. Without superseding the previous
        // request here, a still-pending deferred completion from an earlier, unrelated
        // workspace selection can fire on the next run loop turn and clobber this panel
        // with its stale captured panel ID.
        if let targetPanelId, let panel = tab.panels[targetPanelId] {
            focusTransitionCoordinator.beginTransition(
                to: FocusTransitionCoordinator.Owner(
                    workspaceID: tabId,
                    panelID: targetPanelId,
                    intent: panel.preferredFocusIntentForActivation()
                ),
                reason: .workspaceSelection
            )
        }

        if let targetPanelId, tab.panels[targetPanelId] != nil {
            _ = dismissNotificationOnDirectInteraction(tabId: tabId, surfaceId: targetPanelId)
        }
        return true
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = workspace(withId: tabId) else { return }
        tab.focusPanel(surfaceId)
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
#if DEBUG
        let nextId = tabs[nextIndex].id
        debugPrepareWorkspaceSwitch("next", from: currentId, to: nextId)
#endif
        activateWorkspaceCycleHotWindow()
        selectedTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
#if DEBUG
        let prevId = tabs[prevIndex].id
        debugPrepareWorkspaceSwitch("prev", from: currentId, to: prevId)
#endif
        activateWorkspaceCycleHotWindow()
        selectedTabId = tabs[prevIndex].id
    }

    private func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
#if DEBUG
        let switchId = debugWorkspaceSwitchId
        let switchDtMs = debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
#endif
        if !isWorkspaceCycleHot {
            isWorkspaceCycleHot = true
#if DEBUG
            dlog(
                "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
#if DEBUG
        if hadPendingCooldown {
            dlog(
                "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
        }
#endif
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
#if DEBUG
                await MainActor.run {
                    guard let self else { return }
                    let dtMs = self.debugWorkspaceSwitchStartTime > 0
                        ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                        : 0
                    dlog(
                        "ws.hot.cooldownCanceled id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                    )
                }
#endif
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.hot.off id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                )
#endif
                self.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

#if DEBUG
    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard debugWorkspaceSwitchId > 0, debugWorkspaceSwitchStartTime > 0 else { return nil }
        return (debugWorkspaceSwitchId, debugWorkspaceSwitchStartTime)
    }

    private func debugPrimeWorkspaceSwitchTrigger(_ trigger: String, to target: UUID?) {
        guard selectedTabId != target else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = trigger
        debugPendingWorkspaceSwitchTarget = target
    }

    private func debugPrepareWorkspaceSwitch(_ trigger: String, from: UUID?, to: UUID?) {
        guard from != to else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            debugPreparedWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = nil
        debugPendingWorkspaceSwitchTarget = nil
        debugBeginWorkspaceSwitch(trigger: trigger, from: from, to: to)
        debugPreparedWorkspaceSwitchTarget = to
    }

    private func debugBeginWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        dlog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) trigger=\(trigger) " +
            "from=\(Self.debugShortWorkspaceId(from)) to=\(Self.debugShortWorkspaceId(to)) " +
            "hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(tabs.count)"
        )
    }

    private static func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select_index", to: tabs[index].id)
#endif
        selectedTabId = tabs[index].id
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectedTabId = lastTab.id
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        // Cmd+T should always focus the newly created surface.
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true)
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedTabId,
              let tab = workspace(withId: selectedTabId) else { return }
        tab.moveFocus(direction: direction)
    }

    // MARK: - Recent Tab History Navigation

    private func recordTabInHistory(_ tabId: UUID) {
        // If we're not at the end of history, truncate forward history
        if historyIndex < tabHistory.count - 1 {
            tabHistory = Array(tabHistory.prefix(historyIndex + 1))
        }

        // Don't add duplicate consecutive entries
        if tabHistory.last == tabId {
            return
        }

        tabHistory.append(tabId)

        // Trim history if it exceeds max size
        if tabHistory.count > maxHistorySize {
            tabHistory.removeFirst(tabHistory.count - maxHistorySize)
        }

        historyIndex = tabHistory.count - 1
    }

    func navigateBack() {
        guard historyIndex > 0 else { return }

        // Find the previous valid tab in history (skip closed tabs)
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
        }
    }

    func navigateForward() {
        guard historyIndex < tabHistory.count - 1 else { return }

        // Find the next valid tab in history (skip closed tabs)
        let targetIndex = historyIndex + 1
        while targetIndex < tabHistory.count {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            // Don't increment targetIndex since we removed the element
        }
    }

    var canNavigateBack: Bool {
        historyIndex > 0 && tabHistory.prefix(historyIndex).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    var canNavigateForward: Bool {
        historyIndex < tabHistory.count - 1 && tabHistory.suffix(from: historyIndex + 1).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    /// Flash the currently focused panel so the user can visually confirm focus.
    func triggerFocusFlash() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return }
        tab.triggerFocusFlash(panelId: panelId)
    }

    /// Ensure AppKit first responder matches the currently focused terminal panel.
    /// This keeps real keyboard events (including Ctrl+D) on the same panel as the
    /// bonsplit focus indicator after rapid split topology changes.
    func ensureFocusedTerminalFirstResponder() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let terminal = tab.terminalPanel(for: panelId) else { return }
        terminal.hostedView.ensureFocus(for: tab.id, surfaceId: panelId)
    }

    /// Reconcile keyboard routing before terminal control shortcuts (e.g. Ctrl+D).
    ///
    /// Source of truth for pane focus is bonsplit's focused pane + selected tab.
    /// Keyboard delivery must converge AppKit first responder to that model state, not mutate
    /// the model from whatever first responder happened to be during reparenting transitions.
    func reconcileFocusedPanelFromFirstResponderForKeyboard() {
        ensureFocusedTerminalFirstResponder()
    }

    /// Get a terminal panel by ID
    func terminalPanel(tabId: UUID, panelId: UUID) -> TerminalPanel? {
        guard let tab = workspace(withId: tabId) else { return nil }
        return tab.terminalPanel(for: panelId)
    }

    /// Get the panel for a surface ID (terminal panels use surface ID as panel ID)
    func surface(for tabId: UUID, surfaceId: UUID) -> TerminalSurface? {
        terminalPanel(tabId: tabId, panelId: surfaceId)?.surface
    }

}

// MARK: - Direction Types for Backwards Compatibility

/// Split direction for backwards compatibility with old API
enum SplitDirection {
    case left, right, up, down

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var orientation: SplitOrientation {
        isHorizontal ? .horizontal : .vertical
    }

    /// If true, insert the new pane on the "first" side (left/top).
    /// If false, insert on the "second" side (right/bottom).
    var insertFirst: Bool {
        self == .left || self == .up
    }
}

/// Resize direction for backwards compatibility
enum ResizeDirection {
    case left, right, up, down

    var splitOrientation: String {
        switch self {
        case .left, .right:
            return "horizontal"
        case .up, .down:
            return "vertical"
        }
    }

    /// A split controls the target pane's right/bottom edge when the target is
    /// the first child, and left/top edge when the target is the second child.
    var requiresPaneInFirstChild: Bool {
        switch self {
        case .right, .down:
            return true
        case .left, .up:
            return false
        }
    }

    /// Positive values move the divider toward the second child (right/down).
    var dividerDeltaSign: CGFloat {
        requiresPaneInFirstChild ? 1 : -1
    }
}

extension Notification.Name {
    static let commandPaletteToggleRequested = Notification.Name("programa.commandPaletteToggleRequested")
    static let commandPaletteRequested = Notification.Name("programa.commandPaletteRequested")
    static let commandPaletteSwitcherRequested = Notification.Name("programa.commandPaletteSwitcherRequested")
    static let commandPaletteSubmitRequested = Notification.Name("programa.commandPaletteSubmitRequested")
    static let commandPaletteDismissRequested = Notification.Name("programa.commandPaletteDismissRequested")
    static let commandPaletteRenameTabRequested = Notification.Name("programa.commandPaletteRenameTabRequested")
    static let commandPaletteRenameWorkspaceRequested = Notification.Name("programa.commandPaletteRenameWorkspaceRequested")
    static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name("programa.commandPaletteEditWorkspaceDescriptionRequested")
    static let commandPaletteMoveSelection = Notification.Name("programa.commandPaletteMoveSelection")
    static let commandPaletteRenameInputInteractionRequested = Notification.Name("programa.commandPaletteRenameInputInteractionRequested")
    static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("programa.commandPaletteRenameInputDeleteBackwardRequested")
    static let feedbackComposerRequested = Notification.Name("programa.feedbackComposerRequested")
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
    static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
    static let terminalPortalVisibilityDidChange = Notification.Name("programa.terminalPortalVisibilityDidChange")
    static let browserPortalRegistryDidChange = Notification.Name("programa.browserPortalRegistryDidChange")
}
