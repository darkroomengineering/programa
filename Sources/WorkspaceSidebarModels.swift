// Sidebar/telemetry value types
// (status, metadata, log, progress, git-branch, and pull-request models).

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

struct SidebarWorkspaceHierarchyEntry: Equatable {
    let id: UUID
    let parentId: UUID?
    let isFolder: Bool
    let isCollapsed: Bool
}

enum SidebarWorkspaceHierarchy {
    static func depth(of id: UUID, entries: [SidebarWorkspaceHierarchyEntry]) -> Int {
        let entriesById = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var depth = 0
        var currentId = id
        var visited: Set<UUID> = []
        while visited.insert(currentId).inserted,
              let parentId = entriesById[currentId]?.parentId,
              parentId != currentId,
              entriesById[parentId] != nil {
            depth += 1
            currentId = parentId
        }
        return depth
    }

    static func visibleWorkspaceIds(_ entries: [SidebarWorkspaceHierarchyEntry]) -> [UUID] {
        let entryIds = Set(entries.map(\.id))
        var childrenByParent: [UUID: [SidebarWorkspaceHierarchyEntry]] = [:]
        for entry in entries {
            guard let parentId = entry.parentId,
                  parentId != entry.id,
                  entryIds.contains(parentId) else { continue }
            childrenByParent[parentId, default: []].append(entry)
        }
        var result: [UUID] = []
        var emitted: Set<UUID> = []
        var hidden: Set<UUID> = []

        func hideDescendants(of entry: SidebarWorkspaceHierarchyEntry) {
            for child in childrenByParent[entry.id] ?? [] where hidden.insert(child.id).inserted {
                hideDescendants(of: child)
            }
        }

        func append(_ entry: SidebarWorkspaceHierarchyEntry, visiting: Set<UUID>) {
            guard !visiting.contains(entry.id), emitted.insert(entry.id).inserted else { return }
            result.append(entry.id)
            if entry.isFolder && entry.isCollapsed {
                hideDescendants(of: entry)
                return
            }
            let nextVisiting = visiting.union([entry.id])
            for child in childrenByParent[entry.id] ?? [] {
                append(child, visiting: nextVisiting)
            }
        }

        for entry in entries {
            let hasValidParent = entry.parentId.map {
                $0 != entry.id && entryIds.contains($0)
            } ?? false
            if !hasValidParent {
                append(entry, visiting: [])
            }
        }
        // Malformed relationships (for example, a cycle in a user-edited snapshot) stay visible
        // instead of silently dropping a workspace from the sidebar.
        result.append(contentsOf: entries.lazy.map(\.id).filter {
            !hidden.contains($0) && emitted.insert($0).inserted
        })
        return result
    }

    static func childCount(of folderId: UUID, in entries: [SidebarWorkspaceHierarchyEntry]) -> Int {
        entries.lazy.filter { $0.parentId == folderId }.count
    }
}

struct SidebarStatusEntry: Equatable {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: SidebarMetadataFormat
    let timestamp: Date

    init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date()
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
    }
}

struct SidebarMetadataBlock: Equatable {
    let key: String
    let markdown: String
    let priority: Int
    let timestamp: Date
}

enum SidebarMetadataFormat: String {
    case plain
    case markdown
}

struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}

enum SidebarLogLevel: String, Sendable {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry: Equatable {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState: Equatable {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState: Equatable {
    let branch: String
    let isDirty: Bool
}

struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

enum SidebarPullRequestStatus: String, Sendable {
    case open
    case merged
    case closed
}

enum SidebarPullRequestChecksStatus: String, Sendable {
    case pass
    case fail
    case pending
}

func normalizedSidebarBranchName(_ branch: String?) -> String? {
    guard let branch else { return nil }
    let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

struct SidebarPullRequestState: Equatable {
    let number: Int
    let label: String
    let url: URL
    let status: SidebarPullRequestStatus
    let branch: String?
    let checks: SidebarPullRequestChecksStatus?

    init(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) {
        self.number = number
        self.label = label
        self.url = url
        self.status = status
        self.branch = normalizedSidebarBranchName(branch)
        self.checks = checks
    }
}

enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    struct BranchDirectoryEntry: Equatable {
        let branch: String?
        let isDirty: Bool
        let directory: String?
    }

    fileprivate static func normalizedDirectory(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func relativePathFromTilde(_ directory: String) -> String? {
        let normalized = normalizedDirectory(directory)
        switch normalized {
        case "~":
            return ""
        case let path? where path.hasPrefix("~/"):
            return String(path.dropFirst(2))
        default:
            return nil
        }
    }

    private static func expandedTildePath(
        _ directory: String,
        homeDirectoryForTildeExpansion: String?
    ) -> String {
        guard let relativePath = relativePathFromTilde(directory),
              let homeDirectory = normalizedDirectory(homeDirectoryForTildeExpansion) else {
            return directory
        }
        if relativePath.isEmpty {
            return homeDirectory
        }
        return NSString(string: homeDirectory).appendingPathComponent(relativePath)
    }

    static func canonicalDirectoryKey(
        _ directory: String?,
        homeDirectoryForTildeExpansion: String?
    ) -> String? {
        guard let directory = normalizedDirectory(directory) else { return nil }
        let expanded = expandedTildePath(
            directory,
            homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
        )
        let standardized = NSString(string: expanded).standardizingPath
        let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func preferredDisplayedDirectory(
        existing: String?,
        replacement: String?,
        homeDirectoryForTildeExpansion: String?
    ) -> String? {
        guard let replacement = normalizedDirectory(replacement) else { return existing }
        guard let existing = normalizedDirectory(existing) else { return replacement }

        let existingUsesTilde = relativePathFromTilde(existing) != nil
        let replacementUsesTilde = relativePathFromTilde(replacement) != nil
        if existingUsesTilde != replacementUsesTilde {
            return replacementUsesTilde ? existing : replacement
        }

        if canonicalDirectoryKey(existing, homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion)
            == canonicalDirectoryKey(
                replacement,
                homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
            ) {
            return existing
        }

        return replacement
    }

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniquePullRequests(
        orderedPanelIds: [UUID],
        panelPullRequests: [UUID: SidebarPullRequestState],
        fallbackPullRequest: SidebarPullRequestState?
    ) -> [SidebarPullRequestState] {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .merged: return 3
            case .open: return 2
            case .closed: return 1
            }
        }

        func checksPriority(_ checks: SidebarPullRequestChecksStatus?) -> Int {
            switch checks {
            case .fail: return 3
            case .pending: return 2
            case .pass: return 1
            case nil: return 0
            }
        }

        func normalizedReviewURLKey(for url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }

            // Treat URL variants that differ only by query/fragment as the same review item.
            components.query = nil
            components.fragment = nil
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            var path = components.path
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            return "\(scheme)://\(host)\(port)\(path)"
        }

        func reviewKey(for state: SidebarPullRequestState) -> String {
            "\(state.label.lowercased())#\(state.number)|\(normalizedReviewURLKey(for: state.url))"
        }

        var orderedKeys: [String] = []
        var pullRequestsByKey: [String: SidebarPullRequestState] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelPullRequests[panelId] else { continue }
            let key = reviewKey(for: state)
            if pullRequestsByKey[key] == nil {
                orderedKeys.append(key)
                pullRequestsByKey[key] = state
                continue
            }
            guard let existing = pullRequestsByKey[key] else { continue }
            if statusPriority(state.status) > statusPriority(existing.status) {
                pullRequestsByKey[key] = state
            } else if state.status == existing.status,
                      checksPriority(state.checks) > checksPriority(existing.checks) {
                pullRequestsByKey[key] = state
            }
        }

        if orderedKeys.isEmpty, let fallbackPullRequest {
            return [fallbackPullRequest]
        }

        return orderedKeys.compactMap { pullRequestsByKey[$0] }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        homeDirectoryForTildeExpansion: String?,
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchDirectoryEntry] {
        struct EntryKey: Hashable {
            let directory: String?
            let branch: String?
        }

        struct MutableEntry {
            var branch: String?
            var isDirty: Bool
            var directory: String?
        }

        let normalized = normalizedDirectory
        let normalizedFallbackBranch = normalized(fallbackBranch?.branch)
        let shouldUseFallbackBranchPerPanel = !orderedPanelIds.contains {
            normalized(panelBranches[$0]?.branch) != nil
        }
        let defaultBranchForPanels = shouldUseFallbackBranchPerPanel ? normalizedFallbackBranch : nil
        let defaultBranchDirty = shouldUseFallbackBranchPerPanel ? (fallbackBranch?.isDirty ?? false) : false

        var order: [EntryKey] = []
        var entries: [EntryKey: MutableEntry] = [:]

        for panelId in orderedPanelIds {
            let panelBranch = normalized(panelBranches[panelId]?.branch)
            let branch = panelBranch ?? defaultBranchForPanels
            let directory = normalized(panelDirectories[panelId])
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(
                directory,
                homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
            ) {
                // Keep one line per directory and allow the latest branch state to overwrite.
                key = EntryKey(directory: directoryKey, branch: nil)
            } else {
                key = EntryKey(directory: nil, branch: branch)
            }

            guard key.directory != nil || key.branch != nil else { continue }

            if var existing = entries[key] {
                if key.directory != nil {
                    if let branch {
                        existing.branch = branch
                        existing.isDirty = panelDirty
                    } else if existing.branch == nil {
                        existing.isDirty = panelDirty
                    }
                    existing.directory = preferredDisplayedDirectory(
                        existing: existing.directory,
                        replacement: directory,
                        homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
                    )
                    entries[key] = existing
                } else if panelDirty {
                    existing.isDirty = true
                    entries[key] = existing
                }
            } else {
                order.append(key)
                entries[key] = MutableEntry(branch: branch, isDirty: panelDirty, directory: directory)
            }
        }

        if order.isEmpty {
            let fallbackDirectory = normalized(defaultDirectory)
            if normalizedFallbackBranch != nil || fallbackDirectory != nil {
                return [
                    BranchDirectoryEntry(
                        branch: normalizedFallbackBranch,
                        isDirty: fallbackBranch?.isDirty ?? false,
                        directory: fallbackDirectory
                    )
                ]
            }
        }

        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return BranchDirectoryEntry(
                branch: entry.branch,
                isDirty: entry.isDirty,
                directory: entry.directory
            )
        }
    }
}
