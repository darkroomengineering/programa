import XCTest
import Bonsplit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Workspace fix sweep (WKSP cluster): runtime behavior of the new seams.
@MainActor
final class WorkspaceFixSweepWKSPTests: XCTestCase {
    // MARK: 01 implicit Return only for a live, unblocked agent

    func testCanAutoSubmitOnlyForFreshUnblockedAgent() {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let now = Date()
        let working = UUID(), blocked = UUID(), stale = UUID(), shell = UUID()
        workspace.panelAgentPresence = [
            working: AgentPresence(state: .working, source: .hooks, lastEventAt: now),
            blocked: AgentPresence(state: .blocked, source: .hooks, lastEventAt: now),
            stale: AgentPresence(
                state: .working, source: .hooks,
                lastEventAt: now.addingTimeInterval(-AgentPresence.staleThreshold - 1)
            ),
        ]
        XCTAssertTrue(workspace.canAutoSubmitToAgent(panelId: working, now: now))
        XCTAssertFalse(workspace.canAutoSubmitToAgent(panelId: blocked, now: now), "a y/n prompt must not get an implicit Return")
        XCTAssertFalse(workspace.canAutoSubmitToAgent(panelId: stale, now: now))
        XCTAssertFalse(workspace.canAutoSubmitToAgent(panelId: shell, now: now), "a plain shell must never get an implicit Return")
    }

    // MARK: 03 / 04 presence and notifications follow a moved surface

    private struct NotificationFixture {
        let store: TerminalNotificationStore
        let cleanup: () -> Void
    }

    private func installNotificationStore() -> NotificationFixture {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let original = appDelegate.notificationStore
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.notificationStore = store
        return NotificationFixture(store: store) {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.notificationStore = original
        }
    }

    private func unreadNotification(tabId: UUID, surfaceId: UUID) -> TerminalNotification {
        TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "t", subtitle: "", body: "b", createdAt: Date(), isRead: false
        )
    }

    func testDetachAttachMovesAgentPresenceToDestination() throws {
        let fixture = installNotificationStore()
        defer { fixture.cleanup() }
        let source = Workspace(), destination = Workspace()
        defer { source.teardownAllPanels(); destination.teardownAllPanels() }
        _ = try XCTUnwrap(source.focusedPanelId)
        let moving = try XCTUnwrap(source.newTerminalSurfaceInFocusedPane(focus: false)).id
        source.updatePanelAgentState(panelId: moving, state: .blocked, source: .hooks)
        let expected = try XCTUnwrap(source.panelAgentPresence[moving])

        let detached = try XCTUnwrap(source.detachSurface(panelId: moving))
        let pane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertEqual(destination.attachDetachedSurface(detached, inPane: pane, focus: false), moving)

        XCTAssertEqual(destination.panelAgentPresence[moving], expected)
        XCTAssertNil(source.panelAgentPresence[moving])
        XCTAssertNil(SidebarAgentIndicator.make(for: source))
        XCTAssertEqual(SidebarAgentIndicator.make(for: destination)?.tint, .blocked)
    }

    func testRekeyNotificationsMovesUnreadBadgeBetweenWorkspaces() {
        let fixture = installNotificationStore()
        defer { fixture.cleanup() }
        let a = UUID(), b = UUID(), surface = UUID(), otherSurface = UUID()
        fixture.store.replaceNotificationsForTesting([
            unreadNotification(tabId: a, surfaceId: surface),
            unreadNotification(tabId: a, surfaceId: otherSurface),
        ])

        fixture.store.rekeyNotifications(surfaceId: surface, fromTabId: a, toTabId: b)

        XCTAssertEqual(fixture.store.unreadCount(forTabId: a), 1, "the surface that stayed keeps its badge")
        XCTAssertEqual(fixture.store.unreadCount(forTabId: b), 1)
    }

    func testDetachAttachRekeysNotificationsToDestinationWorkspace() throws {
        let fixture = installNotificationStore()
        defer { fixture.cleanup() }
        let source = Workspace(), destination = Workspace()
        defer { source.teardownAllPanels(); destination.teardownAllPanels() }
        _ = try XCTUnwrap(source.focusedPanelId)
        let moving = try XCTUnwrap(source.newTerminalSurfaceInFocusedPane(focus: false)).id
        fixture.store.replaceNotificationsForTesting([unreadNotification(tabId: source.id, surfaceId: moving)])

        let detached = try XCTUnwrap(source.detachSurface(panelId: moving))
        let pane = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertNotNil(destination.attachDetachedSurface(detached, inPane: pane, focus: false))

        XCTAssertEqual(fixture.store.unreadCount(forTabId: source.id), 0)
        XCTAssertEqual(fixture.store.unreadCount(forTabId: destination.id), 1)
    }

    // MARK: 05 review comments deliver only to a real source terminal

    func testReviewSendClosureFailsWhenSourceTerminalIsGone() {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let review = ReviewPanel(
            workspaceId: workspace.id, sourceSurfaceId: UUID(),
            directory: "/tmp", mode: .uncommitted, baseBranch: "main"
        )
        XCTAssertFalse(workspace.makeReviewSendClosure(for: review)("comment"))
    }

    func testReviewSendClosureDeliversWhenSourceTerminalIsInCreatingWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let source = try XCTUnwrap(workspace.focusedPanelId)
        let review = ReviewPanel(
            workspaceId: workspace.id, sourceSurfaceId: source,
            directory: "/tmp", mode: .uncommitted, baseBranch: "main"
        )
        XCTAssertTrue(workspace.makeReviewSendClosure(for: review)("comment"))
    }

    // MARK: 08 manifest pattern validation and sample cap

    private func manifest(recognize: [String], statePatterns: [String]) -> AgentManifest {
        AgentManifest(
            version: 1, agent: "test", displayName: "Test",
            recognize: .init(processNames: [], screenPatterns: recognize),
            states: [.init(
                bucket: "working", priority: 50, anchorLastNLines: 6,
                patterns: statePatterns, confidence: "high", sourceNotes: nil
            )]
        )
    }

    func testInvalidPatternsReportsEveryUncompilablePattern() {
        XCTAssertEqual(manifest(recognize: ["("], statePatterns: ["ok"]).invalidPatterns(), ["("])
        XCTAssertEqual(manifest(recognize: ["ok"], statePatterns: ["good", "[unclosed"]).invalidPatterns(), ["[unclosed"])
        XCTAssertEqual(manifest(recognize: ["ok"], statePatterns: ["good"]).invalidPatterns(), [])
    }

    func testOversizedSampleKeepsTailAndDropsHead() {
        let rule = manifest(recognize: ["TAILMARK"], statePatterns: ["TAILMARK"])
        let headRule = manifest(recognize: ["HEADONLY"], statePatterns: ["HEADONLY"])
        let filler = String(repeating: "filler line\n", count: 12_000)
        XCTAssertGreaterThan(filler.utf8.count, 64 * 1024 * 2)

        let tailSample = filler + "TAILMARK"
        XCTAssertTrue(rule.recognizes(text: tailSample))
        XCTAssertEqual(rule.classify(text: tailSample)?.bucket, "working")

        let headSample = "HEADONLY\n" + filler
        XCTAssertFalse(headRule.recognizes(text: headSample), "text beyond the cap must not match")
    }

    // MARK: 16 pane cap vetoes a split before building a panel

    private func makeFourPaneWorkspace() throws -> Workspace {
        let workspace = Workspace()
        for _ in 0..<3 {
            let source = try XCTUnwrap(workspace.focusedPanelId)
            XCTAssertNotNil(workspace.newTerminalSplit(from: source, orientation: .horizontal))
        }
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, SplitPolicy.maxPanesPerWorkspace)
        return workspace
    }


    // MARK: 19 background tab creation leaves selection and focus alone

    private func twoPaneFixture() throws -> (workspace: Workspace, backgroundPane: PaneID, selectedTab: TabID, focusedPane: PaneID) {
        let workspace = Workspace()
        let first = try XCTUnwrap(workspace.focusedPanelId)
        let backgroundPane = try XCTUnwrap(workspace.paneId(forPanelId: first))
        let selected = try XCTUnwrap(workspace.bonsplitController.selectedTab(inPane: backgroundPane)?.id)
        XCTAssertNotNil(workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: true))
        let focused = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        XCTAssertNotEqual(focused, backgroundPane)
        return (workspace, backgroundPane, selected, focused)
    }

    func testNewTerminalSurfaceWithoutSelectKeepsSelectionAndFocus() throws {
        let fixture = try twoPaneFixture()
        defer { fixture.workspace.teardownAllPanels() }
        let workspace = fixture.workspace

        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: fixture.backgroundPane, selectInPane: false))

        XCTAssertEqual(workspace.bonsplitController.selectedTab(inPane: fixture.backgroundPane)?.id, fixture.selectedTab)
        XCTAssertEqual(workspace.bonsplitController.focusedPaneId, fixture.focusedPane)
        let newTab = try XCTUnwrap(workspace.surfaceIdFromPanelId(panel.id))
        XCTAssertTrue(workspace.bonsplitController.tabs(inPane: fixture.backgroundPane).contains { $0.id == newTab })
    }

}
