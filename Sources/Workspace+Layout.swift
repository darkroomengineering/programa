// Extracted from Workspace.swift (nuclear-review #98): programa.json custom layout application (applyCustomLayout and its tree/pane helpers).

@preconcurrency import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText
import WebKit

@MainActor
private final class PendingTerminalInputState {
    var resolved = false
    var observer: NSObjectProtocol?
}

extension Workspace {

    /// Applies a named layout from `store` (named-layout configs, see
    /// docs/plans/worktree-and-layouts.md) into this workspace. Shared by `layout.apply` and
    /// `worktree.create --layout` -- both just need "apply this saved layout with this
    /// baseCwd" once the target workspace already exists. Returns false if no such layout
    /// exists (caller surfaces this as `layout_not_found`).
    @discardableResult
    func applyNamedLayout(name: String, baseCwd: String, store: ProgramaLayoutStore) -> Bool {
        guard let saved = store.load(name: name) else { return false }
        applyCustomLayout(saved.layout, baseCwd: baseCwd)
        return true
    }

    /// Captures this workspace's live pane/split tree back into a `ProgramaLayoutNode`, the
    /// reverse direction of `applyCustomLayout`. Used by `layout.save`. v1 cuts (documented,
    /// not oversights -- see docs/plans/worktree-and-layouts.md): `command`/`env`/`focus` are
    /// never captured (no live signal for "what's currently running" in a panel, only its
    /// cwd/URL); panes with zero capturable surfaces (e.g. markdown-only, not yet supported by
    /// `ProgramaSurfaceType`) are dropped, which can collapse a split down to its remaining
    /// child or return nil entirely if nothing was capturable.
    func captureCustomLayout() -> ProgramaLayoutNode? {
        captureLayoutNode(from: bonsplitController.treeSnapshot(), baseCwd: currentDirectory)
    }

    private func captureLayoutNode(from node: ExternalTreeNode, baseCwd: String) -> ProgramaLayoutNode? {
        switch node {
        case .pane(let paneNode):
            let surfaces = captureSurfaceDefinitions(fromPaneTabs: paneNode.tabs, baseCwd: baseCwd)
            guard !surfaces.isEmpty else { return nil }
            return .pane(ProgramaPaneDefinition(surfaces: surfaces))

        case .split(let splitNode):
            let first = captureLayoutNode(from: splitNode.first, baseCwd: baseCwd)
            let second = captureLayoutNode(from: splitNode.second, baseCwd: baseCwd)
            switch (first, second) {
            case (.some(let first), .some(let second)):
                guard let direction = ProgramaSplitDirection(rawValue: splitNode.orientation) else { return second }
                return .split(ProgramaSplitDefinition(direction: direction, split: splitNode.dividerPosition, children: [first, second]))
            case (.some(let only), nil), (nil, .some(let only)):
                return only
            case (nil, nil):
                return nil
            }
        }
    }

    private func captureSurfaceDefinitions(fromPaneTabs tabs: [ExternalTab], baseCwd: String) -> [ProgramaSurfaceDefinition] {
        tabs.compactMap { tab -> ProgramaSurfaceDefinition? in
            guard let tabUUID = UUID(uuidString: tab.id),
                  let panelId = panelIdFromSurfaceId(TabID(uuid: tabUUID)) else {
                return nil
            }
            let customTitle = panelCustomTitles[panelId]

            if terminalPanel(for: panelId) != nil {
                let absoluteCwd = panelDirectories[panelId] ?? baseCwd
                return ProgramaSurfaceDefinition(
                    type: .terminal,
                    name: customTitle,
                    command: nil,
                    cwd: Self.relativizedCwd(absoluteCwd, baseCwd: baseCwd),
                    env: nil,
                    url: nil,
                    focus: nil
                )
            }

            if let browserPanel = browserPanel(for: panelId) {
                return ProgramaSurfaceDefinition(
                    type: .browser,
                    name: customTitle,
                    command: nil,
                    cwd: nil,
                    env: nil,
                    url: browserPanel.webView.url?.absoluteString,
                    focus: nil
                )
            }

            // Markdown panels have no `ProgramaSurfaceType` counterpart yet (v1 cut).
            return nil
        }
    }

    /// Stores `cwd` relative to `baseCwd` where possible (matching
    /// `ProgramaConfigStore.resolveCwd`'s existing relative-path convention), which is what
    /// makes `worktree create --layout`'s worktree-relative resolution work "for free" on
    /// apply. Returns nil (meaning "same as baseCwd") when they're identical.
    private static func relativizedCwd(_ absoluteCwd: String, baseCwd: String) -> String? {
        guard absoluteCwd != baseCwd else { return nil }
        let normalizedBase = baseCwd.hasSuffix("/") ? baseCwd : baseCwd + "/"
        guard absoluteCwd.hasPrefix(normalizedBase) else { return absoluteCwd }
        return String(absoluteCwd.dropFirst(normalizedBase.count))
    }

    func applyCustomLayout(_ layout: ProgramaLayoutNode, baseCwd: String) {
        guard let rootPaneId = bonsplitController.allPaneIds.first else { return }

        var leaves: [(paneId: PaneID, surfaces: [ProgramaSurfaceDefinition])] = []
        buildCustomLayoutTree(layout, inPane: rootPaneId, leaves: &leaves)

        // First leaf reuses the initial terminal created by addWorkspace;
        // subsequent leaves were created via newTerminalSplit which also seeds
        // a placeholder terminal.
        var focusPanelId: UUID?
        for leaf in leaves {
            populateCustomPane(leaf.paneId, surfaces: leaf.surfaces, baseCwd: baseCwd, focusPanelId: &focusPanelId)
        }

        let liveRoot = bonsplitController.treeSnapshot()
        applyCustomDividerPositions(configNode: layout, liveNode: liveRoot)

        if let focusPanelId {
            focusPanel(focusPanelId)
        }
    }

    private func buildCustomLayoutTree(
        _ node: ProgramaLayoutNode,
        inPane paneId: PaneID,
        leaves: inout [(paneId: PaneID, surfaces: [ProgramaSurfaceDefinition])]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append((paneId: paneId, surfaces: pane.surfaces))

        case .split(let split):
            guard split.children.count == 2 else {
                NSLog("[ProgramaConfig] split node requires exactly 2 children, got %d", split.children.count)
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                      from: anchorPanelId,
                      orientation: split.splitOrientation,
                      insertFirst: false,
                      focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            buildCustomLayoutTree(split.children[0], inPane: paneId, leaves: &leaves)
            buildCustomLayoutTree(split.children[1], inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func populateCustomPane(
        _ paneId: PaneID,
        surfaces: [ProgramaSurfaceDefinition],
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }

        guard !surfaces.isEmpty else { return }

        let firstSurface = surfaces[0]
        if let placeholderPanelId = existingPanelIds.first {
            configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: firstSurface,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }

        for surfaceIndex in 1..<surfaces.count {
            createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: ProgramaSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        switch surface.type {
        case .terminal where surface.cwd != nil || surface.env != nil:
            // Placeholder can't change cwd/env — replace it
            let resolvedCwd = ProgramaConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            }

        case .terminal:
            if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let command = surface.command, let terminal = terminalPanel(for: panelId) {
                sendInputWhenReady(command + "\n", to: terminal)
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = newBrowserSurface(inPane: paneId, url: url, focus: false) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func createNewSurface(
        inPane paneId: PaneID,
        surface: ProgramaSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        switch surface.type {
        case .terminal:
            let resolvedCwd = ProgramaConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = newBrowserSurface(inPane: paneId, url: url, focus: false) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func applyCustomDividerPositions(
        configNode: ProgramaLayoutNode,
        liveNode: ExternalTreeNode
    ) {
        switch (configNode, liveNode) {
        case (.split(let configSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(configSplit.clampedSplitPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            if configSplit.children.count == 2 {
                applyCustomDividerPositions(configNode: configSplit.children[0], liveNode: liveSplit.first)
                applyCustomDividerPositions(configNode: configSplit.children[1], liveNode: liveSplit.second)
            }
        default:
            break
        }
    }

    private func sendInputWhenReady(_ text: String, to panel: TerminalPanel) {
        if panel.surface.surface != nil {
            panel.sendInput(text)
            return
        }

        let state = PendingTerminalInputState()

        state.observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { [weak panel, state] _ in
            MainActor.assumeIsolated {
                guard !state.resolved, let panel else { return }
                state.resolved = true
                if let observer = state.observer { NotificationCenter.default.removeObserver(observer) }
                state.observer = nil
                panel.sendInput(text)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { @MainActor [state] in
            guard !state.resolved else { return }
            state.resolved = true
            if let observer = state.observer { NotificationCenter.default.removeObserver(observer) }
            state.observer = nil
            NSLog("[ProgramaConfig] surface not ready after 3s, dropping command (%d chars)", text.count)
        }
    }
}
