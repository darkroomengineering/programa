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
