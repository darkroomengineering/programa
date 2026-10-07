// OSC 7501 program status: report parsing and the per-terminal record store.
import XCTest
import AppKit

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class ProgramStatusStoreTests: XCTestCase {
    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func parse(_ state: ProgramStatusState?, _ body: String) -> ProgramStatusReport? {
        ProgramStatusReport.parse(state: state, body: Data(body.utf8))
    }

    private func report(_ state: ProgramStatusState?, id: String = "", app: String? = nil) throws -> ProgramStatusReport {
        var body = id.isEmpty ? "" : "id=\(id)"
        if let app { body += (body.isEmpty ? "" : ":") + "app=\(app)" }
        return try XCTUnwrap(parse(state, body))
    }

    // MARK: Parsing

    func testParsesAllFields() throws {
        let parsed = try XCTUnwrap(parse(
            .blocked,
            "id=deploy/us-east:kind=question:progress=40:app=cargo:title=\(b64("Deploy")):msg=\(b64("Pick one"))"
        ))
        XCTAssertEqual(parsed.id, "deploy/us-east")
        XCTAssertEqual(parsed.kind, .question)
        XCTAssertEqual(parsed.progress, 40)
        XCTAssertEqual(parsed.app, "cargo")
        XCTAssertEqual(parsed.title, "Deploy")
        XCTAssertEqual(parsed.msg, "Pick one")
    }

    func testLastValueWinsUnknownKeysAndMalformedPairsIgnored() throws {
        let parsed = try XCTUnwrap(parse(.working, "app=one:bogus=1:junk:app=two:progress=10:progress=20"))
        XCTAssertEqual(parsed.app, "two")
        XCTAssertEqual(parsed.progress, 20)
        XCTAssertEqual(parsed.id, "")
    }

    func testKindIgnoredUnlessBlockedAndProgressIgnoredWhenResting() throws {
        XCTAssertNil(try XCTUnwrap(parse(.working, "kind=auth")).kind)
        XCTAssertEqual(try XCTUnwrap(parse(.blocked, "kind=auth")).kind, .auth)
        XCTAssertNil(try XCTUnwrap(parse(.blocked, "kind=bogus")).kind)
        XCTAssertNil(try XCTUnwrap(parse(.done, "progress=50")).progress)
    }

    func testProgressOutOfRangeAndBadAppReadAsNil() throws {
        XCTAssertNil(try XCTUnwrap(parse(.working, "progress=101")).progress)
        XCTAssertNil(try XCTUnwrap(parse(.working, "progress=-1")).progress)
        XCTAssertNil(try XCTUnwrap(parse(.working, "progress=abc")).progress)
        XCTAssertEqual(try XCTUnwrap(parse(.working, "progress=100")).progress, 100)
        XCTAssertNil(try XCTUnwrap(parse(.working, "app=bad name")).app)
        XCTAssertNil(try XCTUnwrap(parse(.working, "app=\(String(repeating: "a", count: 33))")).app)
    }

    func testBase64PaddingIsOptional() throws {
        XCTAssertEqual(try XCTUnwrap(parse(.done, "msg=aGk")).msg, "hi")
        XCTAssertEqual(try XCTUnwrap(parse(.done, "msg=aGk=")).msg, "hi")
    }

    func testInvalidTextDiscardsWholeReport() {
        XCTAssertNil(parse(.done, "msg=!!!!"))
        XCTAssertNil(parse(.done, "msg=\(b64("a\u{07}b"))"))
        XCTAssertNil(parse(.done, "msg=\(b64("a\u{7F}b"))"))
        XCTAssertNil(parse(.done, "title=\(b64("a\u{85}b"))"))
        XCTAssertNil(parse(.done, "msg=\(b64(String(repeating: "x", count: 2049)))"))
        XCTAssertNotNil(parse(.done, "msg=\(b64(String(repeating: "x", count: 2048)))"))
        XCTAssertNil(parse(.done, "title=\(b64(String(repeating: "x", count: 193)))"))
        XCTAssertNotNil(parse(.done, "title=\(b64(String(repeating: "x", count: 192)))"))
    }

    func testInvalidIdDiscardsWholeReport() {
        XCTAssertNil(parse(.working, "id=a//b"))
        XCTAssertNil(parse(.working, "id=/a"))
        XCTAssertNil(parse(.working, "id=a/"))
        XCTAssertNil(parse(.working, "id=a b"))
        XCTAssertNil(parse(.working, "id=\(String(repeating: "a", count: 33))"))
        XCTAssertNil(parse(.working, "id=a/b/c/d/e/f/g/h/i"))
        XCTAssertNotNil(parse(.working, "id=a/b/c/d/e/f/g/h"))
        let longId = (0..<5).map { _ in String(repeating: "a", count: 30) }.joined(separator: "/")
        XCTAssertNil(parse(.working, "id=\(longId)"))
    }

    func testClearReportHasNoState() throws {
        let parsed = try XCTUnwrap(parse(nil, "id=a"))
        XCTAssertNil(parsed.state)
        XCTAssertEqual(parsed.id, "a")
    }

    /// Ghostty trims keys and values; a clear with a padded `id` must still target that record
    /// rather than falling through to clear-all.
    func testKeysAndValuesAreTrimmedLikeGhostty() throws {
        let parsed = try XCTUnwrap(parse(nil, " id = build "))
        XCTAssertEqual(parsed.id, "build")
        XCTAssertEqual(try XCTUnwrap(parse(.working, "progress= 40 ")).progress, 40)
    }

    // MARK: Store

    func testApplyUpsertsRootAndProjectsLegacyState() throws {
        let store = ProgramStatusStore()
        XCTAssertEqual(store.apply(try report(.working)), .applied(rootTouched: true))
        XCTAssertEqual(store.root?.state, .working)
        XCTAssertEqual(store.apply(try report(.done)), .applied(rootTouched: true))
        XCTAssertEqual(store.root?.state, .done)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(ProgramStatusState.working.legacyAgentState, .working)
        XCTAssertEqual(ProgramStatusState.blocked.legacyAgentState, .blocked)
        for state in [ProgramStatusState.idle, .done, .error] {
            XCTAssertEqual(state.legacyAgentState, .idle)
        }
    }

    func testCapacityAcceptsRecord256RejectsNewRecord257AndAllowsUpdates() throws {
        let store = ProgramStatusStore()
        for index in 0..<ProgramStatusStore.capacity {
            XCTAssertEqual(store.apply(try report(.working, id: "r\(index)")), .applied(rootTouched: false))
        }
        XCTAssertEqual(store.count, 256)
        XCTAssertEqual(store.apply(try report(.working, id: "overflow")), .rejected)
        XCTAssertEqual(store.apply(try report(.working)), .rejected)
        XCTAssertEqual(store.count, 256)
        XCTAssertEqual(store.apply(try report(.done, id: "r0")), .applied(rootTouched: false))
        XCTAssertEqual(store.record(id: "r0")?.state, .done)
    }

    func testClearSubtreeRemovesDescendantsNotSiblingsWithSharedPrefix() throws {
        let store = ProgramStatusStore()
        for id in ["a", "a/b", "a/b/c", "ab", "x"] {
            store.apply(try report(.working, id: id))
        }
        XCTAssertEqual(store.apply(try report(nil, id: "a")), .applied(rootTouched: false))
        XCTAssertNil(store.record(id: "a"))
        XCTAssertNil(store.record(id: "a/b"))
        XCTAssertNil(store.record(id: "a/b/c"))
        XCTAssertNotNil(store.record(id: "ab"))
        XCTAssertNotNil(store.record(id: "x"))
    }

    func testClearWithoutIdRemovesEverything() throws {
        let store = ProgramStatusStore()
        store.apply(try report(.working))
        store.apply(try report(.working, id: "a"))
        XCTAssertEqual(store.apply(try report(nil)), .applied(rootTouched: true))
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.root)
    }

    func testPromptDropsWorkingAndBlockedAtEveryDepthAndKeepsRestingRecords() throws {
        let store = ProgramStatusStore()
        store.apply(try report(.working))
        store.apply(try report(.blocked, id: "a"))
        store.apply(try report(.working, id: "a/b"))
        store.apply(try report(.done, id: "d"))
        store.apply(try report(.error, id: "e/f"))
        store.apply(try report(.idle, id: "i"))
        XCTAssertTrue(store.dropTransient())
        XCTAssertNil(store.root)
        XCTAssertNil(store.record(id: "a"))
        XCTAssertNil(store.record(id: "a/b"))
        XCTAssertEqual(store.record(id: "d")?.state, .done)
        XCTAssertEqual(store.record(id: "e/f")?.state, .error)
        XCTAssertEqual(store.record(id: "i")?.state, .idle)
    }

    func testPromptKeepsRestingRootAndReportsNoRootChange() throws {
        let store = ProgramStatusStore()
        store.apply(try report(.done))
        XCTAssertFalse(store.dropTransient())
        XCTAssertEqual(store.root?.state, .done)
    }

    func testResetAllClearsEverything() throws {
        let store = ProgramStatusStore()
        store.apply(try report(.done))
        store.apply(try report(.done, id: "a"))
        XCTAssertTrue(store.resetAll())
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(store.resetAll())
    }

    func testAppInheritsFromNearestAncestorAtReadTime() throws {
        let store = ProgramStatusStore()
        store.apply(try report(.working, id: "a/b/c"))
        XCTAssertNil(store.record(id: "a/b/c")?.app)
        store.apply(try report(.working, id: "a", app: "cargo"))
        XCTAssertEqual(store.record(id: "a/b/c")?.app, "cargo")
        store.apply(try report(.working, id: "a/b", app: "make"))
        XCTAssertEqual(store.record(id: "a/b/c")?.app, "make")
        store.apply(try report(.working, id: "a", app: "npm"))
        XCTAssertEqual(store.record(id: "a/b")?.app, "make")
        XCTAssertEqual(store.record(id: "a")?.app, "npm")
    }

    // MARK: Wire, wait condition, sidebar

    func testWirePayloadCarriesNoTextOrChildIds() throws {
        let store = ProgramStatusStore()
        store.apply(try XCTUnwrap(parse(.done, "app=cargo:title=\(b64("Secret title")):msg=\(b64("Secret msg"))")))
        store.apply(try report(.working, id: "child"))
        let payload = try XCTUnwrap(store.root?.wirePayload)
        XCTAssertEqual(Set(payload.keys), ["state", "kind", "progress", "app", "has_message", "updated_at"])
        XCTAssertEqual(payload["state"] as? String, "done")
        XCTAssertEqual(payload["has_message"] as? Bool, true)
        XCTAssertEqual(payload["app"] as? String, "cargo")
    }

    func testProgramStateWaitConditions() {
        XCTAssertTrue(ProgramStateWaitCondition.cleared.isSatisfied(by: nil))
        XCTAssertFalse(ProgramStateWaitCondition.cleared.isSatisfied(by: .done))
        XCTAssertTrue(ProgramStateWaitCondition.done.isSatisfied(by: .done))
        XCTAssertFalse(ProgramStateWaitCondition.idle.isSatisfied(by: nil))
        XCTAssertFalse(ProgramStateWaitCondition.anyChange.isSatisfied(by: .working))
        XCTAssertTrue(ProgramStateWaitCondition.anyChange.firesOn(transitionTo: nil))
    }

    func testSidebarIndicatorShowsDoneAndErrorButBlockedSiblingWins() {
        let workspace = Workspace(title: "Test")
        let a = UUID()
        let b = UUID()
        workspace.updatePanelAgentState(panelId: a, state: .idle, source: .program, programState: .done)
        XCTAssertEqual(SidebarAgentIndicator.make(for: workspace)?.tint, .done)
        workspace.updatePanelAgentState(panelId: b, state: .idle, source: .program, programState: .error)
        XCTAssertEqual(SidebarAgentIndicator.make(for: workspace)?.tint, .error)
        workspace.updatePanelAgentState(panelId: a, state: .blocked, source: .hooks)
        XCTAssertEqual(SidebarAgentIndicator.make(for: workspace)?.tint, .blocked)
    }

    func testSidebarTitleStripsLeadingSpinnerGlyphOnly() {
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("◐ CPU usage monitoring"), "CPU usage monitoring")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("✳ Claude Code"), "Claude Code")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("⠋ Build"), "Build")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("🚀 Deploy"), "🚀 Deploy")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("~/Developer"), "~/Developer")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("main"), "main")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("◐"), "◐")
        XCTAssertEqual(SidebarTitle.strippingLeadingStatusGlyph("◐ "), "◐ ")
    }
}
