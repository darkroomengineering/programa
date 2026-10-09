import XCTest
import CoreGraphics
import Bonsplit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    func testBackgroundPrimedWorkspaceStaysMountedButNotPanelVisible() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false,
                shouldPrimeInBackground: true
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0.001
            )
        )
    }

    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true,
                shouldPrimeInBackground: false
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: true,
                renderOpacity: 1
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }
}
