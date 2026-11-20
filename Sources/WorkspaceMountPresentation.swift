import Foundation

enum WorkspaceMountPolicy {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    static let maxMountedWorkspaces = 1
    // During workspace cycling, keep only a minimal handoff pair (selected + retiring).
    static let maxMountedWorkspacesDuringCycle = 2

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        isCycleHot: Bool,
        maxMounted: Int
    ) -> [UUID] {
        if isCycleHot, pinnedIds.isEmpty, let selected { return [selected] }

        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        // Pinned workspaces take priority over the other mounted workspaces.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedTabIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedTabIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, isCycleHot || existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }

}

struct MountedWorkspacePresentation: Equatable {
    let isRenderedVisible: Bool
    let isPanelVisible: Bool
    let renderOpacity: Double
}

enum MountedWorkspacePresentationPolicy {
    static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool,
        shouldPrimeInBackground: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace
        let renderOpacity: Double = {
            if isRenderedVisible {
                return 1
            }
            if shouldPrimeInBackground {
                // Keep the workspace mounted long enough to warm the terminal surface, but do
                // not mark it panel-visible. Visible portal entries intentionally survive
                // transient anchor loss during bonsplit drag/reparent churn.
                return 0.001
            }
            return 0
        }()

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: renderOpacity
        )
    }
}
