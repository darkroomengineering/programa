import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selectedTabId, restored.tabs[1].id)
        XCTAssertEqual(restored.tabs[0].customTitle, "First")
        XCTAssertEqual(restored.tabs[1].customTitle, "Second")
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.selectedTabId)
    }

    func testWorktreeParentPrefersSelectedRepositorySubdirectoryAndHonorsExplicitOwner() throws {
        let manager = TabManager()
        let folder = try XCTUnwrap(manager.selectedWorkspace)
        folder.currentDirectory = "/tmp/project"
        manager.enableWorktreeFolder(folder, repoRoot: "/tmp/project")
        let selected = manager.addWorkspace(workingDirectory: "/tmp/project/Sources/../Sources", select: true)

        let child = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/feature", branch: "feature", repoRoot: "/tmp/project", select: true
        )
        XCTAssertEqual(child.worktreeParentWorkspaceId, selected.id)
        XCTAssertNil(child.worktreeFolderId)

        let folderChild = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/other", branch: "other", repoRoot: "/tmp/project",
            parentWorkspaceId: folder.id, select: true
        )
        XCTAssertEqual(folderChild.worktreeParentWorkspaceId, folder.id)
        XCTAssertEqual(folderChild.worktreeFolderId, folder.worktreeFolderId)
    }

    func testWorktreeParentDoesNotMatchSiblingRepositoryPathPrefix() throws {
        let manager = TabManager()
        let parent = try XCTUnwrap(manager.selectedWorkspace)
        parent.currentDirectory = "/tmp/project"
        _ = manager.addWorkspace(workingDirectory: "/tmp/project-other/Sources", select: true)

        let child = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/feature", branch: "feature", repoRoot: "/tmp/project", select: true
        )
        XCTAssertEqual(child.worktreeParentWorkspaceId, parent.id)
        let detached = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/detached", branch: "detached", repoRoot: "/tmp/project",
            parentWorkspaceId: UUID(), select: true
        )
        XCTAssertNil(detached.worktreeParentWorkspaceId)
    }

    func testOrdinaryWorktreeParentSurvivesEncodedSessionRoundTrip() throws {
        let manager = TabManager()
        let parent = try XCTUnwrap(manager.selectedWorkspace)
        parent.currentDirectory = "/tmp/project"
        parent.setCustomTitle("Parent")
        let child = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/feature", branch: "feature", repoRoot: "/tmp/project", select: true
        )
        child.setCustomTitle("Child")
        let encoded = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        let restoredParent = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Parent" })
        let restoredChild = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Child" })
        XCTAssertNotEqual(restoredParent.id, parent.id)
        XCTAssertEqual(restoredChild.worktreeParentWorkspaceId, restoredParent.id)
        XCTAssertEqual(restored.worktreeChildren(of: restoredParent).map(\.id), [restoredChild.id])
    }

    /// Regression for M9 duplicate-repository parent targeting: two workspaces open the same
    /// repo path, and the worktree child's recorded owner is the *second* one (not the first
    /// in `tabs`, and not whichever one a directory-based re-derivation would prefer). Pre-#336
    /// restore rebuilt worktree parents only from folder membership (`worktreeFolderId`); an
    /// ordinary, non-folder parent like `second` here was never restored at all, so this would
    /// have failed by leaving `restoredChild.worktreeParentWorkspaceId` nil. The current restore
    /// (`TabManager+SessionPersistence.swift`) must instead honor the persisted
    /// `worktreeParentWorkspaceId` by workspace identity, landing the child under `second`.
    func testWorktreeChildRestoresUnderRecordedParentAmongDuplicateRepoPathWorkspaces() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        first.currentDirectory = "/tmp/project"
        first.setCustomTitle("First")
        let second = manager.addWorkspace(workingDirectory: "/tmp/project", select: true)
        second.setCustomTitle("Second")
        XCTAssertEqual(manager.tabs.count, 2, "both workspaces share the same repo path")

        let child = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/feature", branch: "feature", repoRoot: "/tmp/project",
            parentWorkspaceId: second.id, select: true
        )
        child.setCustomTitle("Child")
        XCTAssertEqual(child.worktreeParentWorkspaceId, second.id)

        let encoded = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredFirst = try XCTUnwrap(restored.tabs.first { $0.customTitle == "First" })
        let restoredSecond = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Second" })
        let restoredChild = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Child" })

        XCTAssertEqual(
            restoredChild.worktreeParentWorkspaceId, restoredSecond.id,
            "the child must attach to the specific workspace recorded as its owner"
        )
        XCTAssertNotEqual(
            restoredChild.worktreeParentWorkspaceId, restoredFirst.id,
            "a same-path sibling that is not the recorded owner must never be substituted"
        )
        XCTAssertTrue(restored.worktreeChildren(of: restoredFirst).isEmpty)
        XCTAssertEqual(restored.worktreeChildren(of: restoredSecond).map(\.id), [restoredChild.id])
    }

    /// Regression for M9 hierarchy restoration: a folder with two children plus an independent
    /// ordinary parent/child/grandchild chain must all survive encode -> decode -> restore
    /// together, without cross-linking. `testOrdinaryWorktreeParentSurvivesEncodedSessionRoundTrip`
    /// only exercises a single flat parent/child pair, which a restore that merges every worktree
    /// under one bucket (or only rebuilds folder membership, the pre-#336 behavior) could still
    /// pass. This adds a second, disjoint hierarchy and a selection assertion
    /// (`TabManager+SessionPersistence.swift`'s collapsed-parent selection remap) that only holds
    /// if the folder/child links were actually rebuilt, not merely present as flat rows.
    func testWorkspaceHierarchySurvivesEncodedSessionRoundTrip() throws {
        let manager = TabManager()
        let folder = try XCTUnwrap(manager.selectedWorkspace)
        folder.currentDirectory = "/tmp/folder-repo"
        folder.setCustomTitle("Folder")
        manager.enableWorktreeFolder(folder, repoRoot: "/tmp/folder-repo")
        let folderChildA = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/folder-a", branch: "folder-a", repoRoot: "/tmp/folder-repo",
            parentWorkspaceId: folder.id, select: true
        )
        folderChildA.setCustomTitle("FolderChildA")
        let folderChildB = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/folder-b", branch: "folder-b", repoRoot: "/tmp/folder-repo",
            parentWorkspaceId: folder.id, select: true
        )
        folderChildB.setCustomTitle("FolderChildB")
        manager.setWorktreeFolderCollapsed(folder, collapsed: true)

        let ordinaryParent = manager.addWorkspace(workingDirectory: "/tmp/other-repo", select: true)
        ordinaryParent.setCustomTitle("OrdinaryParent")
        let ordinaryChild = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/other-child", branch: "other-child", repoRoot: "/tmp/other-repo",
            parentWorkspaceId: ordinaryParent.id, select: true
        )
        ordinaryChild.setCustomTitle("OrdinaryChild")
        let grandchild = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/other-grandchild", branch: "other-grandchild", repoRoot: "/tmp/other-repo",
            parentWorkspaceId: ordinaryChild.id, select: true
        )
        grandchild.setCustomTitle("Grandchild")

        // Select a folder child so the collapsed-parent selection remap has something to prove.
        manager.selectWorkspace(folderChildA)

        let encoded = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        func tab(_ title: String) throws -> Workspace {
            try XCTUnwrap(restored.tabs.first { $0.customTitle == title })
        }
        let restoredFolder = try tab("Folder")
        let restoredFolderChildA = try tab("FolderChildA")
        let restoredFolderChildB = try tab("FolderChildB")
        let restoredOrdinaryParent = try tab("OrdinaryParent")
        let restoredOrdinaryChild = try tab("OrdinaryChild")
        let restoredGrandchild = try tab("Grandchild")

        XCTAssertTrue(restoredFolder.isWorktreeFolder)
        XCTAssertTrue(restoredFolder.isWorktreeFolderCollapsed, "collapsed state must survive the round trip")
        XCTAssertEqual(
            Set(restored.worktreeChildren(of: restoredFolder).map(\.id)),
            Set([restoredFolderChildA.id, restoredFolderChildB.id]),
            "both folder children must reattach to the folder, and only to the folder"
        )
        XCTAssertEqual(restoredFolderChildA.worktreeFolderId, restoredFolder.worktreeFolderId)
        XCTAssertEqual(restoredFolderChildB.worktreeFolderId, restoredFolder.worktreeFolderId)

        XCTAssertEqual(
            restored.worktreeChildren(of: restoredOrdinaryParent).map(\.id), [restoredOrdinaryChild.id],
            "the ordinary (non-folder) hierarchy must stay disjoint from the folder hierarchy"
        )
        XCTAssertEqual(
            restored.worktreeChildren(of: restoredOrdinaryChild).map(\.id), [restoredGrandchild.id],
            "a two-level ordinary chain must preserve both links, not just the first level"
        )
        XCTAssertNil(
            restoredGrandchild.worktreeFolderId,
            "a grandchild under a non-folder parent must never inherit folder membership"
        )

        // The pre-selected folder child's selection remaps to its collapsed folder only if the
        // folder/child link the remap depends on was actually rebuilt during restore.
        XCTAssertEqual(
            restored.selectedTabId, restoredFolder.id,
            "selecting a child of a still-collapsed folder must remap to the folder after restore"
        )
    }

    func testLegacyFolderMembershipRestoresWithoutSavedWorkspaceIds() throws {
        let manager = TabManager()
        let folder = try XCTUnwrap(manager.selectedWorkspace)
        manager.enableWorktreeFolder(folder, repoRoot: "/tmp/project")
        _ = manager.addWorktreeWorkspace(
            path: "/tmp/worktrees/feature", branch: "feature", repoRoot: "/tmp/project",
            parentWorkspaceId: folder.id, select: true
        )
        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        for index in snapshot.workspaces.indices {
            snapshot.workspaces[index].id = nil
            snapshot.workspaces[index].worktreeParentWorkspaceId = nil
        }
        let encoded = try JSONEncoder().encode(snapshot)
        let restored = TabManager()
        restored.restoreSessionSnapshot(try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded))
        let restoredFolder = try XCTUnwrap(restored.tabs.first { $0.isWorktreeFolder })
        let child = try XCTUnwrap(restored.tabs.first { !$0.isWorktreeFolder })
        XCTAssertEqual(child.worktreeParentWorkspaceId, restoredFolder.id)
        XCTAssertEqual(child.worktreeFolderId, restoredFolder.worktreeFolderId)
    }

    func testRestoreDetachesInvalidParentReferences() throws {
        let manager = TabManager()
        _ = manager.addWorkspace(select: true)
        let original = manager.sessionSnapshot(includeScrollback: false)
        let firstId = try XCTUnwrap(original.workspaces[0].id)
        let secondId = try XCTUnwrap(original.workspaces[1].id)
        for invalidKind in ["self", "cycle", "missing", "duplicate"] {
            var snapshot = original
            switch invalidKind {
            case "self":
                snapshot.workspaces[0].worktreeParentWorkspaceId = firstId
            case "cycle":
                snapshot.workspaces[0].worktreeParentWorkspaceId = secondId
                snapshot.workspaces[1].worktreeParentWorkspaceId = firstId
            case "missing":
                snapshot.workspaces[0].worktreeParentWorkspaceId = UUID()
            default:
                snapshot.workspaces[1].id = firstId
                snapshot.workspaces[0].worktreeParentWorkspaceId = firstId
            }
            let restored = TabManager()
            restored.restoreSessionSnapshot(snapshot)
            XCTAssertTrue(restored.tabs.allSatisfy { $0.worktreeParentWorkspaceId == nil }, invalidKind)
        }
    }

    func testClosingOrMovingOrdinaryParentDetachesSurvivingChildren() throws {
        for move in [false, true] {
            let manager = TabManager()
            let parent = try XCTUnwrap(manager.selectedWorkspace)
            let child = manager.addWorktreeWorkspace(
                path: "/tmp/worktrees/feature", branch: "feature", repoRoot: "/tmp/project",
                parentWorkspaceId: parent.id, select: true
            )
            if move {
                XCTAssertEqual(manager.detachWorkspace(tabId: parent.id)?.id, parent.id)
            } else {
                manager.closeWorkspace(parent)
            }
            XCTAssertTrue(manager.tabs.contains { $0.id == child.id })
            XCTAssertNil(child.worktreeParentWorkspaceId)
            XCTAssertNil(child.worktreeFolderId)
            XCTAssertEqual(child.worktreeBranch, "feature")
        }
    }
}
