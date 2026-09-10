import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import os

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

private actor BrowserSuggestionRequestRecorder {
    private(set) var requestedHosts: [String] = []

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        requestedHosts.append(url.host ?? "")
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (Data("[]".utf8), response)
    }
}

final class BrowserSearchSuggestionServicePrivacyTests: XCTestCase {
    func testGoogleSuggestionsRequestOnlyTheSelectedProvider() async throws {
        let recorder = BrowserSuggestionRequestRecorder()
        let service = BrowserSearchSuggestionService { request in
            try await recorder.load(request)
        }

        let suggestions = await service.suggestions(engine: .google, query: "private query")
        let requestedHosts = await recorder.requestedHosts

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(
            requestedHosts,
            ["suggestqueries.google.com"],
            "Selecting Google must not disclose the query to DuckDuckGo or Bing fallback endpoints"
        )
    }
}

var cmuxUnitTestInspectorAssociationKey: UInt8 = 0
var cmuxUnitTestInspectorOverrideInstalled = false
var cmuxUnitTestWKWebViewPerformKeyEquivalentOverrideInstalled = false
var cmuxUnitTestWKWebViewPerformKeyEquivalentHook: ((WKWebView, NSEvent) -> Bool?)?

extension ProgramaWebView {
    @objc func cmuxUnitTestInspector() -> NSObject? {
        objc_getAssociatedObject(self, &cmuxUnitTestInspectorAssociationKey) as? NSObject
    }
}

extension WKWebView {
    @objc func cmuxUnitTest_performKeyEquivalent(with event: NSEvent) -> Bool {
        if let hook = cmuxUnitTestWKWebViewPerformKeyEquivalentHook,
           let result = hook(self, event) {
            return result
        }
        return cmuxUnitTest_performKeyEquivalent(with: event)
    }

    func cmuxSetUnitTestInspector(_ inspector: NSObject?) {
        objc_setAssociatedObject(
            self,
            &cmuxUnitTestInspectorAssociationKey,
            inspector,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

func installProgramaUnitTestInspectorOverride() {
    guard !cmuxUnitTestInspectorOverrideInstalled else { return }

    guard let replacementMethod = class_getInstanceMethod(
        ProgramaWebView.self,
        #selector(ProgramaWebView.cmuxUnitTestInspector)
    ) else {
        fatalError("Unable to locate test inspector replacement method")
    }

    let added = class_addMethod(
        ProgramaWebView.self,
        NSSelectorFromString("_inspector"),
        method_getImplementation(replacementMethod),
        method_getTypeEncoding(replacementMethod)
    )
    guard added else {
        fatalError("Unable to install ProgramaWebView _inspector test override")
    }

    cmuxUnitTestInspectorOverrideInstalled = true
}

func installProgramaUnitTestWKWebViewPerformKeyEquivalentOverride() {
    guard !cmuxUnitTestWKWebViewPerformKeyEquivalentOverrideInstalled else { return }

    let originalSelector = #selector(NSResponder.performKeyEquivalent(with:))
    let swizzledSelector = #selector(WKWebView.cmuxUnitTest_performKeyEquivalent(with:))

    guard let originalMethod = class_getInstanceMethod(WKWebView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(WKWebView.self, swizzledSelector) else {
        fatalError("Unable to locate WKWebView performKeyEquivalent methods for swizzling")
    }

    let didAddMethod = class_addMethod(
        WKWebView.self,
        originalSelector,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    )

    if didAddMethod {
        class_replaceMethod(
            WKWebView.self,
            swizzledSelector,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        )
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    cmuxUnitTestWKWebViewPerformKeyEquivalentOverrideInstalled = true
}

private final class BrowserMarkedTextProbeTextView: NSTextView {
    var hasMarkedTextForTesting = false
    private(set) var keyDownEvents: [NSEvent] = []

    override var acceptsFirstResponder: Bool { true }

    override func hasMarkedText() -> Bool {
        hasMarkedTextForTesting
    }

    override func keyDown(with event: NSEvent) {
        keyDownEvents.append(event)
    }
}

final class ProgramaWebViewKeyEquivalentTests: XCTestCase {
    private final class ActionSpy: NSObject {
        private(set) var invoked: Bool = false

        @objc func didInvoke(_ sender: Any?) {
            invoked = true
        }
    }

    private final class WindowCyclingActionSpy: NSObject {
        weak var firstWindow: NSWindow?
        weak var secondWindow: NSWindow?
        private(set) var invocationCount = 0

        @objc func cycleWindow(_ sender: Any?) {
            invocationCount += 1
            guard let firstWindow, let secondWindow else { return }

            if NSApp.keyWindow === firstWindow {
                secondWindow.makeKeyAndOrderFront(nil)
            } else {
                firstWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class FakeWKInspectorResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class DelegateProbeTextView: NSTextView {
        private(set) var delegateReadCount = 0

        override var delegate: NSTextViewDelegate? {
            get {
                delegateReadCount += 1
                return super.delegate
            }
            set {
                super.delegate = newValue
            }
        }
    }

    private final class FieldEditorProbeTextView: NSTextView {
        private(set) var delegateReadCount = 0

        override var delegate: NSTextViewDelegate? {
            get {
                delegateReadCount += 1
                return super.delegate
            }
            set {
                super.delegate = newValue
            }
        }

        override var isFieldEditor: Bool {
            get { true }
            set {}
        }
    }
    func testCmdNRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "n", modifiers: [.command])

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "n", modifiers: [.command], keyCode: 45) // kVK_ANSI_N
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdWRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "w", modifiers: [.command])

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "w", modifiers: [.command], keyCode: 13) // kVK_ANSI_W
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdRRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "r", modifiers: [.command])

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "r", modifiers: [.command], keyCode: 15) // kVK_ANSI_R
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testReturnDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [])

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [], keyCode: 36) // kVK_Return
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    func testCmdReturnDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [.command])

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [.command], keyCode: 36) // kVK_Return
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    func testKeypadEnterDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [])

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [], keyCode: 76) // kVK_ANSI_KeypadEnter
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    @MainActor
    func testCanBlockFirstResponderAcquisitionWhenPaneIsUnfocused() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(webView))

        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(webView.becomeFirstResponder())

        _ = window.makeFirstResponder(webView)
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(firstResponderView === webView || firstResponderView.isDescendant(of: webView))
        }
    }

    @MainActor
    func testPointerFocusAllowanceCanTemporarilyOverrideBlockedFirstResponderAcquisition() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(webView.becomeFirstResponder(), "Expected focus to stay blocked by policy")

        webView.withPointerFocusAllowance {
            XCTAssertTrue(webView.becomeFirstResponder(), "Expected explicit pointer intent to bypass policy")
        }

        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(webView.becomeFirstResponder(), "Expected pointer allowance to be temporary")
    }

    @MainActor
    func testWindowFirstResponderGuardBlocksDescendantWhenPaneIsUnfocused() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(descendant))

        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(window.makeFirstResponder(descendant))

        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(firstResponderView === descendant || firstResponderView.isDescendant(of: webView))
        }
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsDescendantDuringPointerFocusAllowance() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected blocked focus outside pointer allowance")

        _ = window.makeFirstResponder(nil)
        webView.withPointerFocusAllowance {
            XCTAssertTrue(window.makeFirstResponder(descendant), "Expected pointer allowance to bypass guard")
        }

        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected pointer allowance to remain temporary")
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsPointerInitiatedClickFocusWhenPolicyIsBlocked() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected blocked focus without pointer click context")

        let timestamp = ProcessInfo.processInfo.systemUptime
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: descendant)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(descendant), "Expected pointer click context to bypass blocked policy")

        AppDelegate.clearWindowFirstResponderGuardTesting()
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected pointer bypass to be limited to click context")
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsPointerInitiatedClickFocusFromPortalHostedInspectorSibling() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        window.makeKeyAndOrderFront(nil)
        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: host.bounds)
        slot.autoresizingMask = [.width, .height]
        host.addSubview(slot)

        let webView = ProgramaWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        slot.addSubview(webView)

        let inspector = FirstResponderView(frame: NSRect(x: 440, y: 0, width: 200, height: slot.bounds.height))
        inspector.autoresizingMask = [.minXMargin, .height]
        slot.addSubview(inspector)

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(
            window.makeFirstResponder(inspector),
            "Expected portal-hosted inspector focus to stay blocked without pointer click context"
        )

        let pointInInspector = NSPoint(x: inspector.bounds.midX, y: inspector.bounds.midY)
        let pointInWindow = inspector.convert(pointInInspector, to: nil)
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: nil)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(
            window.makeFirstResponder(inspector),
            "Expected portal-hosted inspector click to bypass blocked policy using the overlay hit target"
        )
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsPointerInitiatedClickFocusFromBoundPortalInspectorSiblingWhenHitTestMisses() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let anchor = NSView(frame: NSRect(x: 80, y: 60, width: 480, height: 260))
        contentView.addSubview(anchor)

        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        defer {
            BrowserWindowPortalRegistry.detach(webView: webView)
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected bound portal slot")
            return
        }

        let inspector = FirstResponderView(frame: NSRect(x: 320, y: 0, width: 160, height: slot.bounds.height))
        inspector.autoresizingMask = [.minXMargin, .height]
        slot.addSubview(inspector)

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(
            window.makeFirstResponder(inspector),
            "Expected bound portal inspector focus to stay blocked without pointer click context"
        )

        let pointInInspector = NSPoint(x: inspector.bounds.midX, y: inspector.bounds.midY)
        let pointInWindow = inspector.convert(pointInInspector, to: nil)
        XCTAssertTrue(
            BrowserWindowPortalRegistry.webViewAtWindowPoint(pointInWindow, in: window) === webView,
            "Expected portal registry to resolve the owning web view from a click inside inspector chrome"
        )

        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: nil)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(
            window.makeFirstResponder(inspector),
            "Expected bound portal inspector click to bypass blocked policy through portal registry fallback"
        )
    }

    @MainActor
    func testWindowFirstResponderGuardAvoidsTextViewDelegateLookupForWebViewResolution() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let textView = DelegateProbeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        container.addSubview(textView)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        _ = window.makeFirstResponder(nil)
        _ = window.makeFirstResponder(textView)

        XCTAssertEqual(
            textView.delegateReadCount,
            0,
            "WebView ownership resolution should not touch NSTextView.delegate (unsafe-unretained in AppKit)"
        )
    }

    @MainActor
    func testWindowFirstResponderGuardResolvesTrackedWebViewForFieldEditorResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        let fieldEditor = FieldEditorProbeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))

        window.makeKeyAndOrderFront(nil)
        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(descendant))

        let timestamp = ProcessInfo.processInfo.systemUptime
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: descendant)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        AppDelegate.clearWindowFirstResponderGuardTesting()
        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(window.makeFirstResponder(fieldEditor))
        XCTAssertEqual(
            fieldEditor.delegateReadCount,
            0,
            "Field-editor webview ownership should come from tracked associations, not NSTextView.delegate"
        )
    }

    @MainActor
    func testWindowFirstResponderBypassBlocksSwizzledMakeFirstResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let responder = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        container.addSubview(responder)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        _ = window.makeFirstResponder(nil)
        cmuxWithWindowFirstResponderBypass {
            XCTAssertFalse(
                window.makeFirstResponder(responder),
                "Bypass scope should block transient first-responder changes during devtools auto-restore"
            )
        }
        XCTAssertTrue(window.makeFirstResponder(responder))
    }

    @MainActor
    func testCmdBacktickMenuActionThatChangesKeyWindowOnlyRunsOnceWhenTerminalIsFirstResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let firstContainer = NSView(frame: firstWindow.contentRect(forFrameRect: firstWindow.frame))
        let secondContainer = NSView(frame: secondWindow.contentRect(forFrameRect: secondWindow.frame))
        firstWindow.contentView = firstContainer
        secondWindow.contentView = secondContainer

        let firstTerminal = GhosttyNSView(frame: firstContainer.bounds)
        firstTerminal.autoresizingMask = [.width, .height]
        firstContainer.addSubview(firstTerminal)

        let secondTerminal = GhosttyNSView(frame: secondContainer.bounds)
        secondTerminal.autoresizingMask = [.width, .height]
        secondContainer.addSubview(secondTerminal)

        let spy = WindowCyclingActionSpy()
        spy.firstWindow = firstWindow
        spy.secondWindow = secondWindow
        installMenu(
            target: spy,
            action: #selector(WindowCyclingActionSpy.cycleWindow(_:)),
            key: "`",
            modifiers: [.command]
        )

        secondWindow.orderFront(nil)
        firstWindow.makeKeyAndOrderFront(nil)
        defer {
            secondWindow.orderOut(nil)
            firstWindow.orderOut(nil)
        }

        XCTAssertTrue(firstWindow.makeFirstResponder(firstTerminal))
        guard let event = makeKeyDownEvent(
            key: "`",
            modifiers: [.command],
            keyCode: 50,
            windowNumber: firstWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+` event")
            return
        }

        NSApp.sendEvent(event)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(spy.invocationCount, 1, "Cmd+` should only trigger one window-cycle action")
    }

    @MainActor
    func testCmdBacktickDoesNotRouteDirectlyToMainMenuWhenWebViewIsFirstResponder() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let spy = ActionSpy()
        installMenu(
            target: spy,
            action: #selector(ActionSpy.didInvoke(_:)),
            key: "`",
            modifiers: [.command]
        )

        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(webView))
        guard let event = makeKeyDownEvent(
            key: "`",
            modifiers: [.command],
            keyCode: 50,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+` event")
            return
        }

        XCTAssertFalse(shouldRouteCommandEquivalentDirectlyToMainMenu(event))
        _ = webView.performKeyEquivalent(with: event)
        XCTAssertFalse(
            spy.invoked,
            "ProgramaWebView should not route Cmd+` directly to the menu when WebKit is first responder"
        )
    }

    @MainActor
    func testCmdFDoesNotPreflightIntoPageWhenWebInspectorResponderIsFocused() {
        _ = NSApplication.shared
        installProgramaUnitTestWKWebViewPerformKeyEquivalentOverride()

        let spy = ActionSpy()
        installMenu(spy: spy, key: "f", modifiers: [.command])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let inspectorView = FakeWKInspectorResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        webView.addSubview(inspectorView)

        var forwardedEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
            guard currentWebView === webView else { return nil }
            forwardedEvents.append(event)
            return true
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(inspectorView))
        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

        let consumed = webView.performKeyEquivalent(with: event)

        XCTAssertTrue(consumed, "Expected the menu/inspector path to keep consuming Cmd+F")
        XCTAssertTrue(spy.invoked, "Expected Cmd+F to stay on the menu/inspector path while Web Inspector is focused")
        XCTAssertEqual(
            forwardedEvents.count,
            0,
            "Did not expect ProgramaWebView to preflight Cmd+F into page content while Web Inspector is focused"
        )
    }

    private func installMenu(spy: ActionSpy, key: String, modifiers: NSEvent.ModifierFlags) {
        installMenu(
            target: spy,
            action: #selector(ActionSpy.didInvoke(_:)),
            key: key,
            modifiers: modifiers
        )
    }

    private func installMenu(
        target: NSObject,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let item = NSMenuItem(title: "Test Item", action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        fileMenu.addItem(item)

        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        // Ensure NSApp exists and has a menu for performKeyEquivalent to consult.
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}


private final class BrowserBoundedTransferURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasPrefix("/cookies") {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((request.value(forHTTPHeaderField: "Cookie") ?? "").utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let bodySize = url.path == "/exact" ? 64 : 65
        let headers = url.path == "/exact" ? ["Content-Length": String(bodySize)] : [:]
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 32))
        client?.urlProtocol(self, didLoad: Data(repeating: 0x62, count: bodySize - 32))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class BrowserContextTransferPolicyTests: XCTestCase {
    func testContextTransferOnlySendsCookiesEligibleForDestination() throws {
        func cookie(_ name: String, domain: String = "bounded.test", path: String = "/",
                    secure: Bool = false, expires: Date = Date().addingTimeInterval(3600)) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: "secret", .domain: domain, .path: path, .expires: expires,
            ]
            if secure { properties[.secure] = "TRUE" }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let cookies = try [
            cookie("eligible"), cookie("foreign", domain: "other.test"),
            cookie("wrongpath", path: "/private"), cookie("secure", secure: true),
            cookie("expired", expires: Date().addingTimeInterval(-3600)),
        ]
        let transfer = BrowserContextTransferPolicy.prepareNetworkTransfer(
            to: URL(string: "http://bounded.test/cookies")!, cookies: cookies, referer: nil, userAgent: nil
        )
        transfer.configuration.protocolClasses = [BrowserBoundedTransferURLProtocol.self]
        let loaded = expectation(description: "destination receives only authorized cookies")
        let loader = BrowserBoundedURLLoader(configuration: transfer.configuration)
        loader.load(transfer.request) { result in
            switch result {
            case .success(let value):
                XCTAssertEqual(String(decoding: value.data, as: UTF8.self), "eligible=secret")
            case .failure(let error): XCTFail("Transfer failed: \(error)")
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 2)
    }

    func testContextTransfersKeepProfileCookieStoresIndependent() throws {
        let url = URL(string: "https://bounded.test/cookies")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "profile", .value: "private", .domain: "bounded.test", .path: "/",
        ]))
        let first = BrowserContextTransferPolicy.prepareNetworkTransfer(
            to: url, cookies: [cookie], referer: nil, userAgent: nil
        )
        let second = BrowserContextTransferPolicy.prepareNetworkTransfer(
            to: url, cookies: [], referer: nil, userAgent: nil
        )
        // A response in one profile must never change the next profile's session.
        first.configuration.httpCookieStorage?.setCookie(cookie)
        defer { first.configuration.httpCookieStorage?.deleteCookie(cookie) }
        let loaded = expectation(description: "other profile sends no cookies")
        second.configuration.protocolClasses = [BrowserBoundedTransferURLProtocol.self]
        let loader = BrowserBoundedURLLoader(configuration: second.configuration)
        loader.load(second.request) { result in
            switch result {
            case .success(let value): XCTAssertTrue(value.data.isEmpty, "A transfer leaked another profile's cookie")
            case .failure(let error): XCTFail("Transfer failed: \(error)")
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 2)
    }

    func testPercentDecoderAndFileReaderEnforceExactBoundary() throws {
        XCTAssertEqual(
            BrowserContextTransferPolicy.percentDecodedData("12345678"[...], maximumBytes: 8),
            Data("12345678".utf8)
        )
        XCTAssertNil(BrowserContextTransferPolicy.percentDecodedData("123456789"[...], maximumBytes: 8))
        XCTAssertEqual(
            BrowserContextTransferPolicy.percentDecodedData("%31%32%33"[...], maximumBytes: 3),
            Data("123".utf8)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserContextTransferPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let boundary = directory.appendingPathComponent("boundary")
        let oversized = directory.appendingPathComponent("oversized")
        try Data(repeating: 0x61, count: 32).write(to: boundary)
        try Data(repeating: 0x61, count: 33).write(to: oversized)

        XCTAssertEqual(
            try BrowserContextTransferPolicy.boundedFileData(from: boundary, maximumBytes: 32).count,
            32
        )
        XCTAssertThrowsError(
            try BrowserContextTransferPolicy.boundedFileData(from: oversized, maximumBytes: 32)
        ) { error in
            XCTAssertEqual(error as? BrowserContextTransferPolicy.TransferError, .exceedsByteLimit)
        }
    }

    func testNetworkLoaderAcceptsBoundaryAndRejectsIncrementalOverflow() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserBoundedTransferURLProtocol.self]
        let exactExpectation = expectation(description: "exact boundary")
        let overflowExpectation = expectation(description: "incremental overflow")

        let exactLoader = BrowserBoundedURLLoader(maximumBytes: 64, configuration: configuration)
        exactLoader.load(URLRequest(url: URL(string: "https://bounded.test/exact")!)) { result in
            guard case .success(let value) = result else {
                XCTFail("Expected exact-boundary transfer to succeed: \(result)")
                exactExpectation.fulfill()
                return
            }
            XCTAssertEqual(value.data.count, 64)
            exactExpectation.fulfill()
        }

        let overflowLoader = BrowserBoundedURLLoader(maximumBytes: 64, configuration: configuration)
        overflowLoader.load(URLRequest(url: URL(string: "https://bounded.test/overflow")!)) { result in
            guard case .failure(let error) = result else {
                XCTFail("Expected max+1 transfer to fail")
                overflowExpectation.fulfill()
                return
            }
            XCTAssertEqual(error as? BrowserContextTransferPolicy.TransferError, .exceedsByteLimit)
            overflowExpectation.fulfill()
        }

        wait(for: [exactExpectation, overflowExpectation], timeout: 2)
    }
}

@MainActor
final class ProgramaWebViewContextMenuTests: XCTestCase {
    private func makeRightMouseDownEvent() -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create rightMouseDown event")
        }
        return event
    }

    func testGoogleRedirectNormalizationHandlesDuplicateQueryItems() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let redirect = URL(string: "https://www.google.com/url?q=https%3A%2F%2Fa.example%2Fx&q=https%3A%2F%2Fb.example%2Fy")!

        XCTAssertEqual(
            webView.normalizedLinkedDownloadURLForTesting(redirect).absoluteString,
            "https://a.example/x"
        )
    }

    func testGoogleRedirectNormalizationSkipsInvalidDuplicateBeforeValidValue() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let redirect = URL(string: "https://www.google.com/url?q=javascript%3Aalert%281%29&q=https%3A%2F%2Fsafe.example%2Fasset")!

        XCTAssertEqual(
            webView.normalizedLinkedDownloadURLForTesting(redirect).absoluteString,
            "https://safe.example/asset"
        )
    }

    func testGoogleRedirectNormalizationPreservesCandidatePriority() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let redirect = URL(string: "https://www.google.com/url?q=https%3A%2F%2Fq.example%2Fasset&url=https%3A%2F%2Furl.example%2Fasset&mediaurl=https%3A%2F%2Fmedia.example%2Fasset&imgurl=https%3A%2F%2Fimage.example%2Fasset")!

        XCTAssertEqual(
            webView.normalizedLinkedDownloadURLForTesting(redirect).absoluteString,
            "https://image.example/asset"
        )
    }

    func testGoogleRedirectNormalizationPreservesEmbeddedQueryEncoding() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let redirect = URL(string: "https://www.google.com/url?q=https%3A%2F%2Fexample.com%2Ffile%3Ftoken%3Da%2526b")!

        XCTAssertEqual(
            webView.normalizedLinkedDownloadURLForTesting(redirect).absoluteString,
            "https://example.com/file?token=a%26b"
        )
    }

    func testGoogleRedirectNormalizationPreservesUnresolvedURLs() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let nonGoogleURL = URL(string: "https://example.com/url?q=https%3A%2F%2Fasset.example%2Fx")!
        let unsupportedGoogleURL = URL(string: "https://www.google.com/url?q=javascript%3Aalert%281%29")!

        XCTAssertEqual(webView.normalizedLinkedDownloadURLForTesting(nonGoogleURL), nonGoogleURL)
        XCTAssertEqual(webView.normalizedLinkedDownloadURLForTesting(unsupportedGoogleURL), unsupportedGoogleURL)
    }

    func testWillOpenMenuAddsOpenLinkInDefaultBrowserAndRoutesSelectionToDefaultBrowserOpener() {
        _ = NSApplication.shared
        let webView = ProgramaWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))

        var openedURL: URL?
        webView.contextMenuLinkURLProvider = { _, _, completion in
            completion(URL(string: "https://example.com/docs")!)
        }
        webView.contextMenuDefaultBrowserOpener = { url in
            openedURL = url
            return true
        }

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        guard let defaultBrowserItemIndex = menu.items.firstIndex(where: { $0.title == "Open Link in Default Browser" }) else {
            XCTFail("Expected Open Link in Default Browser item in context menu")
            return
        }
        guard let openLinkIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) else {
            XCTFail("Expected Open Link item in context menu")
            return
        }

        XCTAssertEqual(defaultBrowserItemIndex, openLinkIndex + 1)
        let defaultBrowserItem = menu.items[defaultBrowserItemIndex]
        XCTAssertTrue(defaultBrowserItem.target === webView)
        XCTAssertNotNil(defaultBrowserItem.action)

        let dispatched = NSApp.sendAction(
            defaultBrowserItem.action!,
            to: defaultBrowserItem.target,
            from: defaultBrowserItem
        )
        XCTAssertTrue(dispatched)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testWillOpenMenuSkipsDefaultBrowserItemWhenContextHasNoOpenLinkEntry() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Back", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Forward", action: nil, keyEquivalent: ""))

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertFalse(menu.items.contains { $0.title == "Open Link in Default Browser" })
    }

    func testWillOpenMenuHooksDownloadImageToDiskMenuVariant() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let originalTarget = NSObject()
        let originalAction = NSSelectorFromString("downloadImageToDisk:")
        let downloadItem = NSMenuItem(title: "Download Image As...", action: originalAction, keyEquivalent: "")
        downloadItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImageToDisk")
        downloadItem.target = originalTarget
        menu.addItem(downloadItem)

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertTrue(downloadItem.target === webView)
        XCTAssertNotNil(downloadItem.action)
        XCTAssertNotEqual(downloadItem.action, originalAction)
    }

    func testWillOpenMenuHooksDownloadLinkedFileToDiskMenuVariant() {
        let webView = ProgramaWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let originalTarget = NSObject()
        let originalAction = NSSelectorFromString("downloadLinkToDisk:")
        let downloadItem = NSMenuItem(title: "Download Linked File As...", action: originalAction, keyEquivalent: "")
        downloadItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadLinkToDisk")
        downloadItem.target = originalTarget
        menu.addItem(downloadItem)

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertTrue(downloadItem.target === webView)
        XCTAssertNotNil(downloadItem.action)
        XCTAssertNotEqual(downloadItem.action, originalAction)
    }
}


final class BrowserDevToolsButtonDebugSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserDevToolsButtonDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testIconCatalogIncludesExpandedChoices() {
        XCTAssertGreaterThanOrEqual(BrowserDevToolsIconOption.allCases.count, 10)
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.terminal))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.globe))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.curlyBracesSquare))
    }

    func testIconOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("this.symbol.does.not.exist", forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.iconOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultIcon
        )
    }

    func testColorOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("notAValidColor", forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.colorOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultColor
        )
    }

    func testBrowserToolbarAccessorySpacingDefaultsToTwoWhenUnset() {
        let defaults = makeIsolatedDefaults()
        defaults.removeObject(forKey: BrowserToolbarAccessorySpacingDebugSettings.key)

        XCTAssertEqual(
            BrowserToolbarAccessorySpacingDebugSettings.current(defaults: defaults),
            BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        )
    }

    func testBrowserToolbarAccessorySpacingFallsBackToDefaultForUnsupportedValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(99, forKey: BrowserToolbarAccessorySpacingDebugSettings.key)

        XCTAssertEqual(
            BrowserToolbarAccessorySpacingDebugSettings.current(defaults: defaults),
            BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        )
    }

    func testBrowserProfilePopoverPaddingDefaultsWhenUnset() {
        let defaults = makeIsolatedDefaults()
        defaults.removeObject(forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        defaults.removeObject(forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)

        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
        )
        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultVerticalPadding
        )
    }

    func testBrowserProfilePopoverPaddingFallsBackForUnsupportedValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(-3, forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        defaults.set(999, forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)

        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
        )
        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultVerticalPadding
        )
    }

    func testCopyPayloadUsesPersistedValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(BrowserDevToolsIconOption.scope.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)
        defaults.set(BrowserDevToolsIconColorOption.bonsplitActive.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)
        XCTAssertTrue(payload.contains("browserDevToolsIconName=scope"))
        XCTAssertTrue(payload.contains("browserDevToolsIconColor=bonsplitActive"))
    }
}


final class BrowserThemeSettingsTests: XCTestCase {
    // Returns the isolated defaults instance along with the suite name backing it, so
    // callers can pass `domainName:` to `BrowserThemeSettings.mode(defaults:domainName:)`.
    // That parameter matters here: `UserDefaults.register(defaults:)` (e.g. the one
    // BrowserPanelView.onAppear installs for `modeKey`) applies process-wide across every
    // UserDefaults/suite in the process, not just the instance it was called on — so without
    // passing this suite's own domain name, a completely unrelated test that renders a
    // BrowserPanelView earlier in the run can make this isolated suite's `modeKey` look
    // already-set via that registered default, even though nothing ever explicitly
    // persisted a value to it.
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "BrowserThemeSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, suiteName)
    }

    func testDefaultsMatchConfiguredFallbacks() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        XCTAssertEqual(
            BrowserThemeSettings.mode(defaults: defaults, domainName: suiteName),
            BrowserThemeSettings.defaultMode
        )
    }

    func testModeReadsPersistedValue() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defaults.set(BrowserThemeMode.dark.rawValue, forKey: BrowserThemeSettings.modeKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults, domainName: suiteName), .dark)

        defaults.set(BrowserThemeMode.light.rawValue, forKey: BrowserThemeSettings.modeKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults, domainName: suiteName), .light)
    }

    func testModeMigratesLegacyForcedDarkModeFlag() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defaults.set(true, forKey: BrowserThemeSettings.legacyForcedDarkModeEnabledKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults, domainName: suiteName), .dark)
        XCTAssertEqual(defaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.dark.rawValue)

        let (otherDefaults, otherSuiteName) = makeIsolatedDefaults()
        otherDefaults.set(false, forKey: BrowserThemeSettings.legacyForcedDarkModeEnabledKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: otherDefaults, domainName: otherSuiteName), .system)
        XCTAssertEqual(otherDefaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.system.rawValue)
    }
}


final class BrowserDeveloperToolsShortcutDefaultsTests: XCTestCase {
    func testSafariDefaultShortcutForToggleDeveloperTools() {
        let shortcut = KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultShortcut
        XCTAssertEqual(shortcut.key, "i")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

    func testSafariDefaultShortcutForShowJavaScriptConsole() {
        let shortcut = KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultShortcut
        XCTAssertEqual(shortcut.key, "c")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

}


@MainActor
final class BrowserDeveloperToolsConfigurationTests: XCTestCase {
    func testLifecycleOnlyProgressDoesNotRepublishBrowserChrome() {
        let panel = BrowserPanel(workspaceId: UUID())
        var publishCount = 0
        let cancellable = panel.objectWillChange.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        panel.estimatedProgress = 0.5

        XCTAssertEqual(
            publishCount,
            0,
            "WebKit progress that the browser chrome does not render should not invalidate its SwiftUI observers"
        )
        XCTAssertEqual(panel.estimatedProgress, 0.5)
    }

    func testBrowserPanelEnablesInspectableWebViewAndDeveloperExtras() {
        let panel = BrowserPanel(workspaceId: UUID())
        let developerExtras = panel.webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool
        XCTAssertEqual(developerExtras, true)

        if #available(macOS 13.3, *) {
            XCTAssertTrue(panel.webView.isInspectable)
        }
    }

    func testBrowserPanelRefreshesUnderPageBackgroundColorWhenGhosttyBackgroundChanges() {
        let panel = BrowserPanel(workspaceId: UUID())
        let updatedColor = NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0)
        let updatedOpacity = 0.57

        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: updatedColor,
                GhosttyNotificationKey.backgroundOpacity: updatedOpacity
            ]
        )

        guard let actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB),
              let expected = updatedColor.withAlphaComponent(updatedOpacity).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible under-page background colors")
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.005)
    }

    func testBrowserPanelStartsAsNewTabWithoutLoadingAboutBlank() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertEqual(panel.displayTitle, "New tab")
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertTrue(panel.isShowingNewTabPage)
        XCTAssertNil(panel.webView.url)
        XCTAssertNil(panel.currentURL)
    }

    func testBrowserPanelLeavesNewTabPageStateWhenNavigationStarts() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertTrue(panel.isShowingNewTabPage)
        panel.navigate(to: URL(string: "https://example.com")!)
        XCTAssertFalse(panel.isShowingNewTabPage)
    }

    func testBrowserPanelThemeModeUpdatesWebViewAppearance() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.setBrowserThemeMode(.dark)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        panel.setBrowserThemeMode(.light)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        panel.setBrowserThemeMode(.system)
        XCTAssertNil(panel.webView.appearance)
    }

    func testBrowserPanelRefreshesUnderPageBackgroundColorWithGhosttyOpacity() {
        let panel = BrowserPanel(workspaceId: UUID())
        let updatedColor = NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0)

        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: updatedColor,
                GhosttyNotificationKey.backgroundOpacity: NSNumber(value: 0.57),
            ]
        )

        guard let actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB),
              let expected = updatedColor.withAlphaComponent(0.57).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible under-page background colors")
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.005)
    }
}


@MainActor
final class BrowserInsecureHTTPAlertPresentationTests: XCTestCase {
    private final class BrowserInsecureHTTPAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertThirdButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    func testInsecureHTTPPromptUsesSheetWhenWindowIsAvailable() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.resetInsecureHTTPAlertHooksForTesting() }

        let alertSpy = BrowserInsecureHTTPAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: { window }
        )
        panel.presentInsecureHTTPAlertForTesting(url: URL(string: "http://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }

    func testInsecureHTTPPromptFallsBackToRunModalWithoutWindow() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.resetInsecureHTTPAlertHooksForTesting() }

        let alertSpy = BrowserInsecureHTTPAlertSpy()
        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: { nil }
        )
        panel.presentInsecureHTTPAlertForTesting(url: URL(string: "http://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 1)
    }
}


@MainActor
final class BrowserPasskeyHandoffAlertPresentationTests: XCTestCase {
    private final class BrowserPasskeyHandoffAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertSecondButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    func testPasskeyHandoffPromptUsesSheetWhenWindowIsAvailable() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.resetInsecureHTTPAlertHooksForTesting() }

        let alertSpy = BrowserPasskeyHandoffAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: { window }
        )
        panel.presentPasskeyHandoffAlertForTesting(url: URL(string: "https://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }

    func testPasskeyHandoffPromptFallsBackToRunModalWithoutWindow() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.resetInsecureHTTPAlertHooksForTesting() }

        let alertSpy = BrowserPasskeyHandoffAlertSpy()
        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alertSpy },
            windowProvider: { nil }
        )
        panel.presentPasskeyHandoffAlertForTesting(url: URL(string: "https://example.com")!)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 1)
    }

    func testPasskeyHandoffPromptSuppressedForNonHTTPSchemes() {
        // The handoff script is injected on data:/file: pages too; opening those in an
        // external app (a local file path, or an attacker-authored data: blob) must never
        // happen. The alert is suppressed entirely for any non-http(s) URL, so neither
        // presentation path fires.
        for raw in ["file:///etc/passwd", "data:text/html,<h1>x</h1>", "javascript:alert(1)"] {
            let panel = BrowserPanel(workspaceId: UUID())
            defer { panel.resetInsecureHTTPAlertHooksForTesting() }

            let alertSpy = BrowserPasskeyHandoffAlertSpy()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.configureInsecureHTTPAlertHooksForTesting(
                alertFactory: { alertSpy },
                windowProvider: { window }
            )
            panel.presentPasskeyHandoffAlertForTesting(url: URL(string: raw)!)

            XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0, "scheme \(raw) must not present a handoff alert")
            XCTAssertEqual(alertSpy.runModalCallCount, 0, "scheme \(raw) must not present a handoff alert")
        }
    }

    func testPasskeyHandoffScriptIsRegisteredAlongsideExistingBootstrapScripts() {
        let panel = BrowserPanel(workspaceId: UUID())
        // WKUserContentController does not expose registered message-handler names, but the
        // corresponding document-start user script it was paired with is real runtime state.
        // configureWebViewConfiguration registers exactly 4 atDocumentStart/main-frame-only
        // scripts: telemetry, address-bar-focus tracking, IME composition tracking, and
        // passkey handoff — a count regression here means one of them silently stopped
        // registering.
        let scripts = panel.webView.configuration.userContentController.userScripts
        let documentStartMainFrameScripts = scripts.filter {
            $0.injectionTime == .atDocumentStart && $0.isForMainFrameOnly
        }
        XCTAssertEqual(documentStartMainFrameScripts.count, 4)
    }
}


final class BrowserNavigationNewTabDecisionTests: XCTestCase {
    func testLinkActivatedCmdClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            )
        )
    }

    func testLinkActivatedMiddleClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testLinkActivatedPlainLeftClickStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationMiddleClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testOtherNavigationLeftClickStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testLinkActivatedButtonFourWithoutMiddleIntentStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 4,
                hasRecentMiddleClickIntent: false
            )
        )
    }

    func testLinkActivatedButtonFourWithRecentMiddleIntentOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 4,
                hasRecentMiddleClickIntent: true
            )
        )
    }

    func testLinkActivatedUsesCurrentEventFallbackForMiddleClick() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }

    func testCurrentEventFallbackDoesNotAffectNonLinkNavigation() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .reload,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }

    func testNonLinkNavigationNeverForcesNewTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .reload,
                modifierFlags: [.command],
                buttonNumber: 2
            )
        )
    }
}


final class BrowserPopupDecisionTests: XCTestCase {
    func testLinkActivatedPlainLeftClickDoesNotCreatePopup() {
        XCTAssertFalse(
            browserNavigationShouldCreatePopup(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationPlainLeftClickCreatesPopup() {
        XCTAssertTrue(
            browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationMiddleClickDoesNotCreatePopup() {
        XCTAssertFalse(
            browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testLinkActivatedCmdClickDoesNotCreatePopup() {
        XCTAssertFalse(
            browserNavigationShouldCreatePopup(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            )
        )
    }
}


final class BrowserNilTargetFallbackDecisionTests: XCTestCase {
    func testOtherNavigationDoesNotFallbackToNewTab() {
        XCTAssertFalse(
            browserNavigationShouldFallbackNilTargetToNewTab(
                navigationType: .other
            )
        )
    }

    func testLinkActivatedNavigationFallsBackToNewTab() {
        XCTAssertTrue(
            browserNavigationShouldFallbackNilTargetToNewTab(
                navigationType: .linkActivated
            )
        )
    }
}


final class BrowserPopupContentRectTests: XCTestCase {
    func testExplicitTopOriginCoordinatesConvertToAppKitBottomOrigin() {
        let rect = browserPopupContentRect(
            requestedWidth: 400,
            requestedHeight: 300,
            requestedX: 150,
            requestedTopY: 120,
            visibleFrame: NSRect(x: 100, y: 50, width: 1000, height: 800)
        )

        XCTAssertEqual(rect.origin.x, 150, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 430, accuracy: 0.01)
        XCTAssertEqual(rect.width, 400, accuracy: 0.01)
        XCTAssertEqual(rect.height, 300, accuracy: 0.01)
    }

    func testExplicitCoordinatesClampToVisibleFrame() {
        let rect = browserPopupContentRect(
            requestedWidth: 1400,
            requestedHeight: 1200,
            requestedX: 900,
            requestedTopY: -25,
            visibleFrame: NSRect(x: 100, y: 50, width: 1000, height: 800)
        )

        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 50, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.height, 800, accuracy: 0.01)
    }

    func testMissingCoordinatesCentersPopup() {
        let rect = browserPopupContentRect(
            requestedWidth: 300,
            requestedHeight: 200,
            requestedX: nil,
            requestedTopY: nil,
            visibleFrame: NSRect(x: 100, y: 50, width: 1000, height: 800)
        )

        XCTAssertEqual(rect.origin.x, 450, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 350, accuracy: 0.01)
        XCTAssertEqual(rect.width, 300, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
    }
}


@MainActor
final class BrowserJavaScriptDialogDelegateTests: XCTestCase {
    func testBrowserPanelUIDelegateImplementsJavaScriptDialogSelectors() {
        let panel = BrowserPanel(workspaceId: UUID())
        guard let uiDelegate = panel.webView.uiDelegate as? NSObject else {
            XCTFail("Expected BrowserPanel webView.uiDelegate to be an NSObject")
            return
        }

        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript alert handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript confirm handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript prompt handling"
        )
    }
}


@MainActor
final class BrowserSessionHistoryRestoreTests: XCTestCase {
    private func writeBrowserFixturePage(
        at url: URL,
        title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let html = """
        <html>
        <head><title>\(title)</title></head>
        <body>\(title)</body>
        </html>
        """

        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write browser fixture page: \(error)", file: file, line: line)
            throw error
        }
    }

    private func waitForBrowserPanel(
        _ panel: BrowserPanel,
        url: URL,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if panel.preferredURLStringForOmnibar() == url.absoluteString && !panel.isLoading {
                return
            }
        }

        XCTFail(
            "Timed out waiting for browser panel to load \(url.absoluteString). Current=\(panel.preferredURLStringForOmnibar() ?? "nil") loading=\(panel.isLoading)",
            file: file,
            line: line
        )
    }

    func testSessionNavigationHistorySnapshotUsesRestoredStacks() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)

        let snapshot = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            snapshot.backHistoryURLStrings,
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertEqual(
            snapshot.forwardHistoryURLStrings,
            ["https://example.com/d"]
        )
    }

    func testSessionNavigationHistoryBoundsDirectionsAndURLBytes() {
        let panel = BrowserPanel(workspaceId: UUID())
        let back = (0..<2_050).map { "https://example.com/back/\($0)" }
        let forward = (0..<2_050).map { "https://example.com/forward/\($0)" }
        let oversized = "https://example.com/" + String(
            repeating: "x",
            count: BrowserPanel.maxSessionHistoryURLBytes
        )

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [oversized] + back,
            forwardHistoryURLStrings: forward + [oversized],
            currentURLString: oversized
        )

        let snapshot = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(snapshot.backHistoryURLStrings.count, BrowserPanel.maxSessionHistoryURLsPerDirection)
        XCTAssertEqual(snapshot.backHistoryURLStrings.first, "https://example.com/back/2")
        XCTAssertEqual(snapshot.backHistoryURLStrings.last, "https://example.com/back/2049")
        XCTAssertEqual(snapshot.forwardHistoryURLStrings.count, BrowserPanel.maxSessionHistoryURLsPerDirection)
        XCTAssertEqual(snapshot.forwardHistoryURLStrings.first, "https://example.com/forward/0")
        XCTAssertEqual(snapshot.forwardHistoryURLStrings.last, "https://example.com/forward/2047")
        XCTAssertFalse(snapshot.backHistoryURLStrings.contains(oversized))
        XCTAssertFalse(snapshot.forwardHistoryURLStrings.contains(oversized))
    }

    func testSessionNavigationHistoryBackAndForwardUpdateStacks() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        panel.goBack()
        let afterBack = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(afterBack.backHistoryURLStrings, ["https://example.com/a"])
        XCTAssertEqual(
            afterBack.forwardHistoryURLStrings,
            ["https://example.com/c", "https://example.com/d"]
        )
        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)

        panel.goForward()
        let afterForward = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            afterForward.backHistoryURLStrings,
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertEqual(afterForward.forwardHistoryURLStrings, ["https://example.com/d"])
        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)
    }

    func testGoBackPrefersLiveWKWebViewHistoryBeforeRestoredFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pageA = tempDir.appendingPathComponent("a.html")
        let pageB = tempDir.appendingPathComponent("b.html")
        let pageC = tempDir.appendingPathComponent("c.html")
        try writeBrowserFixturePage(at: pageA, title: "A")
        try writeBrowserFixturePage(at: pageB, title: "B")
        try writeBrowserFixturePage(at: pageC, title: "C")

        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: pageB
        )
        waitForBrowserPanel(panel, url: pageB)

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [pageA.absoluteString],
            forwardHistoryURLStrings: [],
            currentURLString: pageB.absoluteString
        )

        _ = browserLoadRequest(URLRequest(url: pageC), in: panel.webView)
        waitForBrowserPanel(panel, url: pageC)

        let snapshot = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            snapshot.backHistoryURLStrings,
            [pageA.absoluteString, pageB.absoluteString]
        )

        panel.goBack()
        waitForBrowserPanel(panel, url: pageB)

        panel.goBack()
        waitForBrowserPanel(panel, url: pageA)
    }

    func testWebViewReplacementAfterProcessTerminationUpdatesInstanceIdentity() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com")
        )
        let oldWebView = panel.webView
        let oldInstanceID = panel.webViewInstanceID

        panel.debugSimulateWebContentProcessTermination()

        XCTAssertFalse(panel.webView === oldWebView)
        XCTAssertNotEqual(panel.webViewInstanceID, oldInstanceID)
        XCTAssertNotNil(panel.webView.navigationDelegate)
        XCTAssertNotNil(panel.webView.uiDelegate)
    }

    func testWebViewReplacementPreservesEmptyNewTabRenderState() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertFalse(panel.shouldRenderWebView)

        panel.debugSimulateWebContentProcessTermination()

        XCTAssertFalse(panel.shouldRenderWebView)
    }

    func testResetSidebarContextClearsBrowserPanelsIntoNewTabState() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let contextPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let browser = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "https://example.com"),
                focus: false
            )
        )

        browser.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.com/prev"],
            forwardHistoryURLStrings: ["https://example.com/next"],
            currentURLString: "https://example.com/current"
        )
        browser.startFind()

        workspace.statusEntries["task"] = SidebarStatusEntry(key: "task", value: "Issue #1208")
        workspace.metadataBlocks["notes"] = SidebarMetadataBlock(
            key: "notes",
            markdown: "test",
            priority: 0,
            timestamp: Date()
        )
        workspace.progress = SidebarProgressState(value: 0.5, label: "Loading")
        workspace.updatePanelGitBranch(panelId: contextPanelId, branch: "issue-1208", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: contextPanelId,
            number: 1208,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://example.com/pull/1208")),
            status: .open
        )
        workspace.logEntries.append(
            SidebarLogEntry(
                message: "Issue #1208",
                level: .info,
                source: "test",
                timestamp: Date()
            )
        )
        workspace.surfaceListeningPorts[contextPanelId] = [3000]
        workspace.recomputeListeningPorts()

        XCTAssertTrue(browser.shouldRenderWebView)
        XCTAssertNotNil(browser.preferredURLStringForOmnibar())
        XCTAssertTrue(browser.canGoBack)
        XCTAssertTrue(browser.canGoForward)
        XCTAssertNotNil(browser.searchState)
        XCTAssertFalse(workspace.statusEntries.isEmpty)
        XCTAssertFalse(workspace.logEntries.isEmpty)
        XCTAssertFalse(workspace.metadataBlocks.isEmpty)
        XCTAssertNotNil(workspace.progress)
        XCTAssertNotNil(workspace.gitBranch)
        XCTAssertNotNil(workspace.pullRequest)
        XCTAssertEqual(workspace.listeningPorts, [3000])

        let priorWebView = browser.webView
        let priorInstanceID = browser.webViewInstanceID
        workspace.resetSidebarContext(reason: "test")

        XCTAssertTrue(workspace.statusEntries.isEmpty)
        XCTAssertTrue(workspace.logEntries.isEmpty)
        XCTAssertTrue(workspace.metadataBlocks.isEmpty)
        XCTAssertNil(workspace.progress)
        XCTAssertNil(workspace.gitBranch)
        XCTAssertTrue(workspace.panelGitBranches.isEmpty)
        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(workspace.panelPullRequests.isEmpty)
        XCTAssertTrue(workspace.surfaceListeningPorts.isEmpty)
        XCTAssertTrue(workspace.listeningPorts.isEmpty)
        XCTAssertFalse(browser.shouldRenderWebView)
        XCTAssertNil(browser.preferredURLStringForOmnibar())
        XCTAssertFalse(browser.canGoBack)
        XCTAssertFalse(browser.canGoForward)
        XCTAssertNil(browser.searchState)
        XCTAssertFalse(browser.webView === priorWebView)
        XCTAssertNotEqual(browser.webViewInstanceID, priorInstanceID)
    }

}


@MainActor
final class BrowserDeveloperToolsVisibilityPersistenceTests: XCTestCase {
    private final class WKInspectorProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class FakeInspector: NSObject {
        enum HideBehavior {
            case unsupported
            case noEffect
            case hides
        }

        private(set) var attachCount = 0
        private(set) var showCount = 0
        private(set) var hideCount = 0
        private(set) var closeCount = 0
        private let hideBehavior: HideBehavior
        private var visible = false
        private var attached = false

        init(hideBehavior: HideBehavior = .unsupported) {
            self.hideBehavior = hideBehavior
            super.init()
        }

        override func responds(to aSelector: Selector!) -> Bool {
            guard NSStringFromSelector(aSelector) == "hide" else {
                return super.responds(to: aSelector)
            }
            return hideBehavior != .unsupported
        }

        @objc func isVisible() -> Bool {
            visible
        }

        @objc func isAttached() -> Bool {
            attached
        }

        @objc func attach() {
            attachCount += 1
            attached = true
            show()
        }

        @objc func show() {
            showCount += 1
            visible = true
        }

        @objc func hide() {
            hideCount += 1
            guard hideBehavior == .hides else { return }
            visible = false
        }

        @objc func close() {
            closeCount += 1
            visible = false
            attached = false
        }
    }

    override class func setUp() {
        super.setUp()
        installProgramaUnitTestInspectorOverride()
    }

    private func makePanelWithInspector(
        hideBehavior: FakeInspector.HideBehavior = .unsupported
    ) -> (BrowserPanel, FakeInspector) {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector(hideBehavior: hideBehavior)
        panel.webView.cmuxSetUnitTestInspector(inspector)
        return (panel, inspector)
    }

    private func findHostContainerView(in root: NSView) -> WebViewRepresentable.HostContainerView? {
        if let host = root as? WebViewRepresentable.HostContainerView {
            return host
        }
        for subview in root.subviews {
            if let host = findHostContainerView(in: subview) {
                return host
            }
        }
        return nil
    }

    private func waitForDeveloperToolsTransitions(
        timeout: TimeInterval = 2.0,
        until condition: (() -> Bool)? = nil
    ) {
        // Give real headroom under a full serial suite run, where the main queue can
        // carry a genuine backlog from other tests' pending async work. When a
        // completion condition is supplied, poll for it directly instead of trusting
        // a fixed spin alone — a queued transition (e.g. toggleDeveloperTools' coalesced
        // hide) can still be in flight when the spin ends under CI contention.
        guard let condition else {
            RunLoop.current.run(until: Date().addingTimeInterval(timeout))
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if condition() { return }
        }
    }

    private func findWindowBrowserSlotView(in root: NSView) -> WindowBrowserSlotView? {
        if let slot = root as? WindowBrowserSlotView {
            return slot
        }
        for subview in root.subviews {
            if let slot = findWindowBrowserSlotView(in: subview) {
                return slot
            }
        }
        return nil
    }

    func testRestoreReopensInspectorAfterAttachWhenPreferredVisible() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate WebKit closing inspector during detach/reattach churn.
        inspector.close()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 1)

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testSyncRespectsManualCloseAndPreventsUnexpectedRestore() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate user closing inspector before detach.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector()

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testSyncCanPreserveVisibleIntentDuringDetachChurn() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate a transient close caused by view detach, not user intent.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: true)
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testSyncDoesNotRepublishHiddenDeveloperToolsIntentWhenInspectorAlreadyHidden() {
        let (panel, inspector) = makePanelWithInspector(hideBehavior: .hides)

        XCTAssertTrue(panel.showDeveloperTools())
        waitForDeveloperToolsTransitions()
        XCTAssertTrue(panel.isDeveloperToolsVisible())

        inspector.hide()
        XCTAssertFalse(panel.isDeveloperToolsVisible())

        panel.syncDeveloperToolsPreferenceFromInspector()
        waitForDeveloperToolsTransitions()

        var publishCount = 0
        let cancellable = panel.objectWillChange.sink {
            publishCount += 1
        }
        defer { _ = cancellable }

        panel.syncDeveloperToolsPreferenceFromInspector()

        XCTAssertEqual(
            publishCount,
            0,
            "Repeated hidden-inspector syncs should not republish the same hidden DevTools intent"
        )
    }

    func testForcedRefreshAfterAttachKeepsVisibleInspectorState() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)

        // The force-refresh request should be one-shot.
        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testRefreshRequestTracksPendingStateUntilRestoreRuns() {
        let (panel, _) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        XCTAssertTrue(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())
    }

    func testRapidToggleCoalescesToFinalVisibleIntentWithoutExtraInspectorCalls() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        waitForDeveloperToolsTransitions()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)
    }

    func testRapidToggleQueuesHideAfterOpenTransitionSettles() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        waitForDeveloperToolsTransitions(timeout: 10.0) {
            inspector.closeCount == 1
        }

        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 1)
    }

    func testToggleDeveloperToolsFallsBackToCloseWhenHideDoesNotConcealInspector() {
        let (panel, inspector) = makePanelWithInspector(hideBehavior: .noEffect)

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())

        XCTAssertTrue(panel.toggleDeveloperTools())

        XCTAssertEqual(inspector.hideCount, 1)
        XCTAssertEqual(inspector.closeCount, 1)
        XCTAssertFalse(panel.isDeveloperToolsVisible())
    }

    func testTransientHideAttachmentPreserveFollowsDeveloperToolsIntent() {
        let (panel, _) = makePanelWithInspector()

        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.hideDeveloperTools())
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testWebViewDismantleKeepsPortalHostedWebViewAttachedWhenDeveloperToolsIntentIsVisible() {
        let (panel, _) = makePanelWithInspector()
        let paneId = PaneID(id: UUID())
        XCTAssertTrue(panel.showDeveloperTools())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 30, y: 30, width: 180, height: 140))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        XCTAssertNotNil(panel.webView.superview)

        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: true,
            useLocalInlineHosting: false,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            paneTopChromeHeight: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        WebViewRepresentable.dismantleNSView(anchor, coordinator: coordinator)

        XCTAssertNotNil(panel.webView.superview)
        window.orderOut(nil)
    }

    func testWebViewDismantleKeepsPortalHostedWebViewAttachedWhenDeveloperToolsIntentIsHidden() {
        let (panel, _) = makePanelWithInspector()
        let paneId = PaneID(id: UUID())
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 150))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        XCTAssertNotNil(panel.webView.superview)

        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: true,
            useLocalInlineHosting: false,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            paneTopChromeHeight: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        WebViewRepresentable.dismantleNSView(anchor, coordinator: coordinator)

        XCTAssertNotNil(panel.webView.superview)
        window.orderOut(nil)
    }

    func testTransientHideAttachmentPreserveDisablesForSideDockedInspectorLayout() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertTrue(panel.showDeveloperTools())

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        panel.webView.frame = NSRect(x: 0, y: 0, width: 120, height: host.bounds.height)
        host.addSubview(panel.webView)

        let inspectorContainer = NSView(
            frame: NSRect(x: 120, y: 0, width: host.bounds.width - 120, height: host.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        host.addSubview(inspectorContainer)

        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testTransientHideAttachmentPreserveStaysEnabledForBottomDockedInspectorLayout() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertTrue(panel.showDeveloperTools())

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        panel.webView.frame = NSRect(x: 0, y: 80, width: host.bounds.width, height: host.bounds.height - 80)
        host.addSubview(panel.webView)

        let inspectorContainer = NSView(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 80))
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        host.addSubview(inspectorContainer)

        XCTAssertTrue(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testOffWindowReplacementLocalHostDoesNotStealVisibleDevToolsWebView() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertTrue(panel.showDeveloperTools())

        let paneId = PaneID(id: UUID())
        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: false,
            useLocalInlineHosting: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            paneTopChromeHeight: 0
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let visibleHosting = NSHostingView(rootView: representable)
        visibleHosting.frame = contentView.bounds
        visibleHosting.autoresizingMask = [.width, .height]
        contentView.addSubview(visibleHosting)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        visibleHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let visibleHost = findHostContainerView(in: visibleHosting) else {
            XCTFail("Expected visible local host")
            return
        }
        guard let visibleSlot = panel.webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected visible local inline slot")
            return
        }

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: visibleSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        visibleSlot.addSubview(inspectorView)
        panel.webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: visibleSlot.bounds.width,
            height: visibleSlot.bounds.height - inspectorView.frame.height
        )
        visibleSlot.layoutSubtreeIfNeeded()

        let detachedRoot = NSView(frame: visibleHosting.frame)
        let offWindowHosting = NSHostingView(rootView: representable)
        offWindowHosting.frame = detachedRoot.bounds
        offWindowHosting.autoresizingMask = [.width, .height]
        detachedRoot.addSubview(offWindowHosting)
        detachedRoot.layoutSubtreeIfNeeded()
        offWindowHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(findHostContainerView(in: offWindowHosting), "Expected off-window replacement host")
        XCTAssertTrue(visibleHost.window === window)
        XCTAssertTrue(
            panel.webView.superview === visibleSlot,
            "An off-window replacement host should not steal a visible DevTools-hosted web view during split zoom churn"
        )
        XCTAssertTrue(
            inspectorView.superview === visibleSlot,
            "An off-window replacement host should leave DevTools companion views in the visible local host"
        )
    }

    func testVisibleReplacementLocalHostNormalizesBottomDockedInspectorFrames() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertTrue(panel.showDeveloperTools())

        let paneId = PaneID(id: UUID())
        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: false,
            useLocalInlineHosting: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            paneTopChromeHeight: 0
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let narrowHosting = NSHostingView(rootView: representable)
        narrowHosting.frame = NSRect(x: 180, y: 0, width: 180, height: 240)
        contentView.addSubview(narrowHosting)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        narrowHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let initialSlot = panel.webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected initial local inline slot")
            return
        }

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: initialSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        initialSlot.addSubview(inspectorView)
        panel.webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: initialSlot.bounds.width,
            height: initialSlot.bounds.height - inspectorView.frame.height
        )
        initialSlot.layoutSubtreeIfNeeded()

        let replacementHosting = NSHostingView(rootView: representable)
        replacementHosting.frame = contentView.bounds
        replacementHosting.autoresizingMask = [.width, .height]
        contentView.addSubview(replacementHosting, positioned: .above, relativeTo: narrowHosting)
        contentView.layoutSubtreeIfNeeded()
        replacementHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        replacementHosting.rootView = representable
        contentView.layoutSubtreeIfNeeded()
        replacementHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        narrowHosting.removeFromSuperview()
        contentView.layoutSubtreeIfNeeded()
        replacementHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let replacementHost = findHostContainerView(in: replacementHosting),
              let replacementSlot = findWindowBrowserSlotView(in: replacementHost) else {
            XCTFail("Expected replacement local inline host")
            return
        }

        XCTAssertTrue(
            panel.webView.superview === replacementSlot,
            "A visible replacement local host should take over the hosted page"
        )
        XCTAssertTrue(
            inspectorView.superview === replacementSlot,
            "A visible replacement local host should move the DevTools companion views with the page"
        )
        XCTAssertEqual(inspectorView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(inspectorView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(inspectorView.frame.width, replacementSlot.bounds.width, accuracy: 0.5)
        XCTAssertEqual(inspectorView.frame.height, 72, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.minY, 72, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.width, replacementSlot.bounds.width, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.height, replacementSlot.bounds.height - 72, accuracy: 0.5)
    }
}


final class BrowserOmnibarCommandNavigationTests: XCTestCase {
    func testArrowNavigationDeltaRequiresFocusedAddressBarAndNoModifierFlags() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: false,
                flags: [],
                keyCode: 126
            )
        )
        XCTAssertNil(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                keyCode: 126
            )
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 126
            ),
            -1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 125
            ),
            1
        )
    }

    func testArrowNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.capsLock],
                keyCode: 126
            ),
            -1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.capsLock],
                keyCode: 125
            ),
            1
        )
    }

    func testCommandNavigationDeltaRequiresFocusedAddressBarAndCommandOrControlOnly() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: false,
                flags: [.command],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "n"
            ),
            1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "p"
            ),
            -1
        )

        XCTAssertNil(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .shift],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "p"
            ),
            -1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "n"
            ),
            1
        )
    }

    func testCommandNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control, .capsLock],
                chars: "n"
            ),
            1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .capsLock],
                chars: "p"
            ),
            -1
        )
    }

    func testSubmitOnReturnIgnoresCapsLockModifier() {
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: []))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.capsLock]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift, .capsLock]))
        XCTAssertFalse(browserOmnibarShouldSubmitOnReturn(flags: [.command, .capsLock]))
    }
}


final class BrowserIMEKeyDownRoutingTests: XCTestCase {
    @MainActor
    func testWindowPerformKeyEquivalentDoesNotForwardReturnDuringMarkedTextComposition() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = BrowserMarkedTextProbeTextView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        responder.hasMarkedTextForTesting = true
        webView.addSubview(responder)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        let consumed = window.performKeyEquivalent(with: event)

        XCTAssertFalse(consumed, "Return should stay in the IME path while marked text is active")
        XCTAssertTrue(responder.hasMarkedText(), "Marked text should still be active until the input method commits it")
        XCTAssertEqual(responder.keyDownEvents.count, 0, "Return should not be force-forwarded to the browser responder during IME composition")
    }

    @MainActor
    func testWindowPerformKeyEquivalentDoesNotForwardKeypadEnterDuringMarkedTextComposition() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = ProgramaWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = BrowserMarkedTextProbeTextView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        responder.hasMarkedTextForTesting = true
        webView.addSubview(responder)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 76
        ) else {
            XCTFail("Failed to construct keypad Enter event")
            return
        }

        let consumed = window.performKeyEquivalent(with: event)

        XCTAssertFalse(consumed, "Keypad Enter should stay in the IME path while marked text is active")
        XCTAssertTrue(responder.hasMarkedText(), "Marked text should still be active until the input method commits it")
        XCTAssertEqual(responder.keyDownEvents.count, 0, "Keypad Enter should not be force-forwarded to the browser responder during IME composition")
    }
}


final class BrowserReturnKeyDownRoutingTests: XCTestCase {
    func testRoutesForReturnWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: []
            )
        )
    }

    func testRoutesForKeypadEnterWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true,
                flags: []
            )
        )
    }

    func testDoesNotRouteForNonEnterKey() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 13,
                firstResponderIsBrowser: true,
                flags: []
            )
        )
    }

    func testDoesNotRouteWhenFirstResponderIsNotBrowser() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: false,
                flags: []
            )
        )
    }

    func testDoesNotRouteReturnWhenBrowserFirstResponderHasMarkedText() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
    }

    func testDoesNotRouteKeypadEnterWhenBrowserFirstResponderHasMarkedText() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
    }

    func testRoutesForShiftReturnWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.shift]
            )
        )
    }

    func testDoesNotRouteForCommandShiftReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.command, .shift]
            )
        )
    }

    func testDoesNotRouteForCommandReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.command]
            )
        )
    }

    func testDoesNotRouteForOptionReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.option]
            )
        )
    }

    func testDoesNotRouteForControlReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.control]
            )
        )
    }
}


final class BrowserZoomShortcutActionTests: XCTestCase {
    func testZoomInSupportsEqualsAndPlusVariants() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "=", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "+", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command, .shift], chars: "+", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "+", keyCode: 30),
            .zoomIn
        )
    }

    func testZoomOutSupportsMinusAndUnderscoreVariants() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "-", keyCode: 27),
            .zoomOut
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command, .shift], chars: "_", keyCode: 27),
            .zoomOut
        )
    }

    func testZoomInSupportsShiftedLiteralFromDifferentPhysicalKey() {
        XCTAssertEqual(
            browserZoomShortcutAction(
                flags: [.command, .shift],
                chars: ";",
                keyCode: 41,
                literalChars: "+"
            ),
            .zoomIn
        )

        XCTAssertNil(
            browserZoomShortcutAction(
                flags: [.command, .shift],
                chars: ";",
                keyCode: 41
            )
        )
    }

    func testZoomRequiresCommandWithoutOptionOrControl() {
        XCTAssertNil(browserZoomShortcutAction(flags: [], chars: "=", keyCode: 24))
        XCTAssertNil(browserZoomShortcutAction(flags: [.command, .option], chars: "=", keyCode: 24))
        XCTAssertNil(browserZoomShortcutAction(flags: [.command, .control], chars: "-", keyCode: 27))
    }

    func testResetSupportsCommandZero() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "0", keyCode: 29),
            .reset
        )
    }
}


final class BrowserZoomShortcutRoutingPolicyTests: XCTestCase {
    func testRoutesWhenGhosttyIsFirstResponderAndShortcutIsZoom() {
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "=",
                keyCode: 24
            )
        )
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "-",
                keyCode: 27
            )
        )
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "0",
                keyCode: 29
            )
        )
    }

    func testDoesNotRouteWhenFirstResponderIsNotGhostty() {
        XCTAssertFalse(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: false,
                flags: [.command],
                chars: "=",
                keyCode: 24
            )
        )
    }

    func testDoesNotRouteForNonZoomShortcuts() {
        XCTAssertFalse(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
    }

    func testRoutesForShiftedLiteralZoomShortcut() {
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command, .shift],
                chars: ";",
                keyCode: 41,
                literalChars: "+"
            )
        )
    }
}


final class BrowserSearchEngineTests: XCTestCase {
    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.google.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testDuckDuckGoSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.duckduckgo.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testBingSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.bing.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.bing.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }
}


final class BrowserSearchSettingsTests: XCTestCase {
    func testCurrentSearchSuggestionsEnabledDefaultsToTrueWhenUnset() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }

    func testCurrentSearchSuggestionsEnabledHonorsExplicitValue() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertFalse(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))

        defaults.set(true, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }
}


private enum BrowserHistoryPersistenceHarnessError: Error {
    case injectedLoadFailure
    case injectedPersistFailure
    case injectedRemoveFailure
    case blockedPersistTimedOut
}

private final class BrowserHistoryPersistenceHarness: Sendable {
    private struct State: Sendable {
        var loadCallCount = 0
        var remainingLoadFailures: Int
        var persistCallCount = 0
        var completedPersistCallCount = 0
        var remainingPersistFailures: Int
        var remainingRemoveFailures: Int
    }

    private let state: OSAllocatedUnfairLock<State>
    private let blockFirstPersist: Bool
    private let firstPersistStarted = DispatchSemaphore(value: 0)
    private let releaseFirstPersist = DispatchSemaphore(value: 0)
    private let persistCompleted = DispatchSemaphore(value: 0)

    init(
        blockFirstPersist: Bool = false,
        loadFailures: Int = 0,
        persistFailures: Int = 0,
        removeFailures: Int = 0
    ) {
        self.blockFirstPersist = blockFirstPersist
        state = OSAllocatedUnfairLock(initialState: State(
            remainingLoadFailures: loadFailures,
            remainingPersistFailures: persistFailures,
            remainingRemoveFailures: removeFailures
        ))
    }

    var persistence: BrowserHistoryStore.Persistence {
        BrowserHistoryStore.Persistence(
            load: { [self] fileURL in
                let shouldFail = state.withLock { state in
                    state.loadCallCount += 1
                    guard state.remainingLoadFailures > 0 else { return false }
                    state.remainingLoadFailures -= 1
                    return true
                }
                if shouldFail {
                    throw BrowserHistoryPersistenceHarnessError.injectedLoadFailure
                }
                return try Data(contentsOf: fileURL)
            },
            persist: { [self] snapshot, fileURL in
                try persist(snapshot, to: fileURL)
            },
            remove: { [self] fileURL in
                let shouldFail = state.withLock { state in
                    guard state.remainingRemoveFailures > 0 else { return false }
                    state.remainingRemoveFailures -= 1
                    return true
                }
                if shouldFail {
                    throw BrowserHistoryPersistenceHarnessError.injectedRemoveFailure
                }
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
                try FileManager.default.removeItem(at: fileURL)
            }
        )
    }

    var persistCallCount: Int {
        state.withLock { $0.persistCallCount }
    }

    var loadCallCount: Int {
        state.withLock { $0.loadCallCount }
    }

    func waitForFirstPersistToStart(timeout: TimeInterval = 2) -> DispatchTimeoutResult {
        firstPersistStarted.wait(timeout: .now() + timeout)
    }

    func releaseBlockedPersist() {
        releaseFirstPersist.signal()
    }

    func waitForPersistCompletions(_ expectedCount: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while state.withLock({ $0.completedPersistCallCount }) < expectedCount {
            guard persistCompleted.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    private func persist(_ snapshot: [BrowserHistoryStore.Entry], to fileURL: URL) throws {
        let outcome = state.withLock { state -> (call: Int, shouldFail: Bool) in
            state.persistCallCount += 1
            let shouldFail = state.remainingPersistFailures > 0
            if shouldFail {
                state.remainingPersistFailures -= 1
            }
            return (state.persistCallCount, shouldFail)
        }
        defer {
            state.withLock { $0.completedPersistCallCount += 1 }
            persistCompleted.signal()
        }

        if blockFirstPersist, outcome.call == 1 {
            firstPersistStarted.signal()
            guard releaseFirstPersist.wait(timeout: .now() + 5) == .success else {
                throw BrowserHistoryPersistenceHarnessError.blockedPersistTimedOut
            }
        }

        if outcome.shouldFail {
            throw BrowserHistoryPersistenceHarnessError.injectedPersistFailure
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}

final class BrowserHistoryStoreTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func decodeEntries(at fileURL: URL) throws -> [BrowserHistoryStore.Entry] {
        try JSONDecoder().decode([BrowserHistoryStore.Entry].self, from: Data(contentsOf: fileURL))
    }

    private func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
            }
        }
    }

    func testPersistenceByteLimitAcceptsBoundaryAndRejectsOneByteOver() throws {
        let boundary = Data(repeating: 0x20, count: BrowserHistoryStore.maxPersistenceBytes)
        XCTAssertEqual(try BrowserHistoryStore.boundedPersistenceData(boundary).count, boundary.count)
        XCTAssertThrowsError(
            try BrowserHistoryStore.boundedPersistenceData(boundary + Data([0x20]))
        ) { error in
            XCTAssertEqual(error as? BrowserHistoryStore.PersistenceLoadError, .exceedsByteLimit)
        }
    }

    func testLoadCapsDecodedEntriesToMostRecentFiveThousand() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        try Data().write(to: fileURL)
        let entries = (0..<5_002).map { index in
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://example.com/\(index)",
                title: nil,
                lastVisited: Date(timeIntervalSince1970: TimeInterval(index)),
                visitCount: 1
            )
        }
        let encoded = try JSONEncoder().encode(entries)
        let persistence = BrowserHistoryStore.Persistence(
            load: { _ in encoded },
            persist: { _, _ in },
            remove: { _ in }
        )
        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL, persistence: persistence) }

        let loaded = await MainActor.run { () -> [BrowserHistoryStore.Entry] in
            XCTAssertTrue(store.loadIfNeeded())
            return store.entries
        }
        XCTAssertEqual(loaded.count, 5_000)
        XCTAssertEqual(loaded.first?.url, "https://example.com/5001")
        XCTAssertEqual(loaded.last?.url, "https://example.com/2")
    }

    func testRecordVisitDedupesAndSuggests() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }

        let u1 = try XCTUnwrap(URL(string: "https://example.com/foo"))
        let u2 = try XCTUnwrap(URL(string: "https://example.com/bar"))

        await MainActor.run {
            store.recordVisit(url: u1, title: "Example Foo")
            store.recordVisit(url: u2, title: "Example Bar")
            store.recordVisit(url: u1, title: "Example Foo Updated")
        }

        let suggestions = await MainActor.run { store.suggestions(for: "foo", limit: 10) }
        XCTAssertEqual(suggestions.first?.url, "https://example.com/foo")
        XCTAssertEqual(suggestions.first?.visitCount, 2)
        XCTAssertEqual(suggestions.first?.title, "Example Foo Updated")
    }

    func testRecordVisitKeepsCaseSensitiveQueryValuesAsDistinctHistoryEntries() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }
        let uppercaseTokenURL = try XCTUnwrap(URL(string: "https://example.com/callback?token=AbC"))
        let lowercaseTokenURL = try XCTUnwrap(URL(string: "https://example.com/callback?token=abc"))

        let initialEntries = await MainActor.run { () -> [BrowserHistoryStore.Entry] in
            store.recordVisit(url: uppercaseTokenURL, title: "Uppercase Token")
            store.recordVisit(url: lowercaseTokenURL, title: "Lowercase Token")
            store.flushPendingSaves()
            return store.entries
        }

        XCTAssertEqual(
            initialEntries.count,
            2,
            "Case-sensitive query values can identify different resources and must not be merged"
        )
        XCTAssertEqual(
            initialEntries.first(where: { $0.url == uppercaseTokenURL.absoluteString })?.visitCount,
            1
        )
        XCTAssertEqual(
            initialEntries.first(where: { $0.url == lowercaseTokenURL.absoluteString })?.visitCount,
            1
        )

        let repeatedEntries = await MainActor.run { () -> [BrowserHistoryStore.Entry] in
            store.recordVisit(url: uppercaseTokenURL, title: "Uppercase Token Revisited")
            store.flushPendingSaves()
            return store.entries
        }

        XCTAssertEqual(repeatedEntries.count, 2)
        XCTAssertEqual(
            repeatedEntries.first(where: { $0.url == uppercaseTokenURL.absoluteString })?.visitCount,
            2,
            "Revisiting a URL must increment only its exact query-value identity"
        )
        XCTAssertEqual(
            repeatedEntries.first(where: { $0.url == lowercaseTokenURL.absoluteString })?.visitCount,
            1,
            "A differently cased query value must retain its independent visit count"
        )
    }

    func testRecordVisitDedupesEquivalentPercentEscapeHexCase() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }
        let lowercaseEscapeURL = try XCTUnwrap(
            URL(string: "https://example.com/callback?next=%2faccount")
        )
        let uppercaseEscapeURL = try XCTUnwrap(
            URL(string: "https://example.com/callback?next=%2Faccount")
        )

        let entries = await MainActor.run { () -> [BrowserHistoryStore.Entry] in
            store.recordVisit(url: lowercaseEscapeURL, title: "Lowercase Escape")
            store.recordVisit(url: uppercaseEscapeURL, title: "Uppercase Escape")
            store.flushPendingSaves()
            return store.entries
        }

        XCTAssertEqual(
            entries.count,
            1,
            "Hexadecimal letter case in a percent escape must not create duplicate history entries"
        )
        XCTAssertEqual(
            entries.first?.visitCount,
            2,
            "Equivalent percent-escape spellings must contribute to the same visit history"
        )
    }

    func testSuggestionsLoadsPersistedHistoryImmediatelyOnFirstQuery() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let now = Date()
        let seededEntries = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 3
            ),
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: now.addingTimeInterval(-120),
                visitCount: 2
            ),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(seededEntries)
        try data.write(to: fileURL, options: [.atomic])

        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }
        let suggestions = await MainActor.run { store.suggestions(for: "go", limit: 10) }

        XCTAssertGreaterThanOrEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first?.url, "https://go.dev/")
        XCTAssertTrue(suggestions.contains(where: { $0.url == "https://www.google.com/" }))
    }

    func testNewerVisitCannotBeOverwrittenByAnOlderSaveThatFinishesLate() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let harness = BrowserHistoryPersistenceHarness(blockFirstPersist: true)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }
        let olderURL = try XCTUnwrap(URL(string: "https://example.com/older"))
        let newerURL = try XCTUnwrap(URL(string: "https://example.com/newer"))

        await MainActor.run {
            store.recordVisit(url: olderURL, title: "Older")
        }
        XCTAssertEqual(
            harness.waitForFirstPersistToStart(),
            .success,
            "The test must control an active old save before creating the newer snapshot"
        )

        await MainActor.run {
            store.recordVisit(url: newerURL, title: "Newer")
        }
        _ = harness.waitForPersistCompletions(1, timeout: 0.5)
        harness.releaseBlockedPersist()
        XCTAssertTrue(
            harness.waitForPersistCompletions(2),
            "The newer debounced snapshot must persist after the old writer is released"
        )

        let persistedURLs = Set(try decodeEntries(at: fileURL).map(\.url))
        XCTAssertEqual(
            persistedURLs,
            Set([olderURL.absoluteString, newerURL.absoluteString]),
            "A late old save must not leave history at a snapshot that omits a newer visit"
        )
    }

    func testClearHistoryWaitsForAnActiveSaveSoDeletedHistoryCannotReappear() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let harness = BrowserHistoryPersistenceHarness(blockFirstPersist: true)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }
        let visitedURL = try XCTUnwrap(URL(string: "https://example.com/private-history"))

        await MainActor.run {
            store.recordVisit(url: visitedURL, title: "Private History")
        }
        XCTAssertEqual(
            harness.waitForFirstPersistToStart(),
            .success,
            "The deletion test must begin while the old history save is active"
        )

        let clearStarted = DispatchSemaphore(value: 0)
        let clearCompleted = DispatchSemaphore(value: 0)
        let clearTask = Task { @MainActor in
            clearStarted.signal()
            store.clearHistory()
            clearCompleted.signal()
        }
        let clearStartedResult = await waitForSignal(clearStarted, timeout: 2)
        XCTAssertEqual(clearStartedResult, .success)
        let clearCompletedBeforeRelease = await waitForSignal(clearCompleted, timeout: 0.5) == .success
        XCTAssertFalse(
            clearCompletedBeforeRelease,
            "clearHistory must not return while an older history write can still recreate the file"
        )

        harness.releaseBlockedPersist()
        XCTAssertTrue(harness.waitForPersistCompletions(1))
        if !clearCompletedBeforeRelease {
            let clearCompletedResult = await waitForSignal(clearCompleted, timeout: 2)
            XCTAssertEqual(clearCompletedResult, .success)
        }
        await clearTask.value
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "History cleared during an active save must remain deleted after clearHistory returns"
        )
    }

    func testFailedClearCannotBeUndoneByTerminationFlush() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let seededEntry = BrowserHistoryStore.Entry(
            id: UUID(),
            url: "https://example.com/history-that-must-stay-cleared",
            title: "History That Must Stay Cleared",
            lastVisited: Date(),
            visitCount: 1
        )
        try JSONEncoder().encode([seededEntry]).write(to: fileURL, options: [.atomic])

        let harness = BrowserHistoryPersistenceHarness(removeFailures: 1)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }

        let loadedEntries = await MainActor.run { () -> [BrowserHistoryStore.Entry] in
            XCTAssertTrue(store.loadIfNeeded())
            return store.entries
        }
        XCTAssertEqual(loadedEntries, [seededEntry])

        await MainActor.run {
            store.clearHistory()
            XCTAssertTrue(store.entries.isEmpty)
            store.flushPendingSaves()
        }

        let finalEntries = await MainActor.run { store.entries }
        XCTAssertTrue(
            finalEntries.isEmpty,
            "A termination flush must not reload history that the user already cleared"
        )
        let persistedEntries = FileManager.default.fileExists(atPath: fileURL.path)
            ? try decodeEntries(at: fileURL)
            : []
        XCTAssertTrue(
            persistedEntries.isEmpty,
            "A transient deletion failure must not let termination persist the cleared URL or title again"
        )
    }

    func testFlushWaitsForAnActiveOldSaveAndPersistsTheNewestSnapshot() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let harness = BrowserHistoryPersistenceHarness(blockFirstPersist: true)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }
        let olderURL = try XCTUnwrap(URL(string: "https://example.com/before-flush"))
        let newerURL = try XCTUnwrap(URL(string: "https://example.com/at-flush"))

        await MainActor.run {
            store.recordVisit(url: olderURL, title: "Before Flush")
        }
        XCTAssertEqual(
            harness.waitForFirstPersistToStart(),
            .success,
            "The flush test must hold the old save before mutating the in-memory history"
        )
        await MainActor.run {
            store.recordVisit(url: newerURL, title: "At Flush")
        }

        let flushStarted = DispatchSemaphore(value: 0)
        let flushCompleted = DispatchSemaphore(value: 0)
        let flushTask = Task { @MainActor in
            flushStarted.signal()
            store.flushPendingSaves()
            flushCompleted.signal()
        }
        let flushStartedResult = await waitForSignal(flushStarted, timeout: 2)
        XCTAssertEqual(flushStartedResult, .success)
        let flushCompletedBeforeRelease = await waitForSignal(flushCompleted, timeout: 0.5) == .success
        XCTAssertFalse(
            flushCompletedBeforeRelease,
            "A flush must not return while an older save can still overwrite its snapshot"
        )

        harness.releaseBlockedPersist()
        XCTAssertTrue(harness.waitForPersistCompletions(2))
        if !flushCompletedBeforeRelease {
            let flushCompletedResult = await waitForSignal(flushCompleted, timeout: 2)
            XCTAssertEqual(flushCompletedResult, .success)
        }
        await flushTask.value
        let persistedURLs = Set(try decodeEntries(at: fileURL).map(\.url))
        XCTAssertEqual(
            persistedURLs,
            Set([olderURL.absoluteString, newerURL.absoluteString]),
            "A flush must be a barrier that leaves the newest history snapshot on disk"
        )
    }

    func testTransientLoadFailurePreservesHistoryAndRetriesBeforeTheNextMutation() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let seededEntry = BrowserHistoryStore.Entry(
            id: UUID(),
            url: "https://example.com/preserved",
            title: "Preserved",
            lastVisited: Date(),
            visitCount: 4
        )
        let originalData = try JSONEncoder().encode([seededEntry])
        try originalData.write(to: fileURL, options: [.atomic])

        let newURL = try XCTUnwrap(URL(string: "https://example.com/after-retry"))
        let harness = BrowserHistoryPersistenceHarness(loadFailures: 1)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }
        await MainActor.run {
            store.recordVisit(url: newURL, title: "After Retry")
            store.flushPendingSaves()
        }

        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            originalData,
            "A read failure must preserve the last known history bytes instead of treating the file as empty"
        )
        XCTAssertEqual(try decodeEntries(at: fileURL).map(\.url), [seededEntry.url])
        XCTAssertEqual(
            harness.persistCallCount,
            0,
            "Flushing an unchanged store after a read failure must not write an empty history array"
        )

        await MainActor.run {
            store.recordVisit(url: newURL, title: "After Retry")
            store.flushPendingSaves()
        }

        XCTAssertEqual(harness.persistCallCount, 1)
        XCTAssertEqual(
            Set(try decodeEntries(at: fileURL).map(\.url)),
            Set([seededEntry.url, newURL.absoluteString]),
            "A transient read failure must retry from the existing file before accepting a later mutation"
        )
    }

    func testReadOnlySuggestionsDoNotRetryAFailedHistoryLoad() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let seededEntry = BrowserHistoryStore.Entry(
            id: UUID(),
            url: "https://example.com/seeded-history",
            title: "Seeded History",
            lastVisited: Date(),
            visitCount: 1
        )
        try JSONEncoder().encode([seededEntry]).write(to: fileURL, options: [.atomic])

        let harness = BrowserHistoryPersistenceHarness(loadFailures: 3)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }

        let results = await MainActor.run {
            [
                store.suggestions(for: "seeded"),
                store.recentSuggestions(),
                store.suggestions(for: "history"),
            ]
        }

        XCTAssertTrue(results.allSatisfy(\.isEmpty))
        XCTAssertEqual(
            harness.loadCallCount,
            1,
            "Read-only omnibar queries must not repeat a failed synchronous history load on every keystroke"
        )
    }

    func testFailedSaveRemainsDirtyAndRetriesWithTheLatestHistory() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let harness = BrowserHistoryPersistenceHarness(persistFailures: 1)
        let store = await MainActor.run {
            BrowserHistoryStore(fileURL: fileURL, persistence: harness.persistence)
        }
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/failed-save"))
        let latestURL = try XCTUnwrap(URL(string: "https://example.com/retry"))

        await MainActor.run {
            store.recordVisit(url: firstURL, title: "Failed Save")
            store.flushPendingSaves()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        await MainActor.run {
            store.recordVisit(url: latestURL, title: "Retry")
            store.flushPendingSaves()
        }

        XCTAssertEqual(harness.persistCallCount, 2)
        XCTAssertEqual(
            Set(try decodeEntries(at: fileURL).map(\.url)),
            Set([firstURL.absoluteString, latestURL.absoluteString]),
            "A failed write must remain retryable, and the retry must persist the newest complete history"
        )
    }
}


@MainActor
final class ProgramaWebViewDragRoutingTests: XCTestCase {
    func testRejectsInternalPaneDragEvenWhenFilePromiseTypesArePresent() {
        XCTAssertTrue(
            ProgramaWebView.shouldRejectInternalPaneDrag([
                DragOverlayRoutingPolicy.bonsplitTabTransferType,
                NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            ])
        )
    }

    func testAllowsRegularExternalFileDrops() {
        XCTAssertFalse(ProgramaWebView.shouldRejectInternalPaneDrag([.fileURL]))
    }
}

final class BrowserLinkOpenSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserLinkOpenSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTerminalLinksDefaultToProgramaBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowser(defaults: defaults))
    }

    func testTerminalLinksPreferenceUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionDefaultsToProgramaBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInProgramaBrowser(defaults: defaults))
    }

    func testSettingsInitialOpenCommandInterceptionValueFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInProgramaBrowserValue(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInProgramaBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInProgramaBrowserValue(defaults: defaults))
    }

    func testExternalOpenPatternsDefaultToEmpty() {
        XCTAssertTrue(BrowserLinkOpenSettings.externalOpenPatterns(defaults: defaults).isEmpty)
    }

    func testExternalOpenLiteralPatternMatchesCaseInsensitively() {
        defaults.set("openai.com/account/usage", forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://platform.OPENAI.com/account/usage",
                defaults: defaults
            )
        )
    }

    func testExternalOpenRegexPatternMatchesCaseInsensitively() {
        defaults.set(
            "re:^https?://[^/]*\\.example\\.com/(billing|usage)",
            forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey
        )
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://FOO.example.com/BILLING",
                defaults: defaults
            )
        )
    }

    func testExternalOpenRegexPatternSupportsDigitCharacterClass() {
        defaults.set(
            "re:^https://example\\.com/usage/\\d+$",
            forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey
        )
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://example.com/usage/42",
                defaults: defaults
            )
        )
    }

    func testExternalOpenPatternsIgnoreInvalidRegexEntries() {
        defaults.set("re:(\nexample.com", forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://example.com/path",
                defaults: defaults
            )
        )
    }

    func testExternalBrowserApplicationURLReturnsNilForEmptyBundleIdentifier() {
        XCTAssertNil(BrowserLinkOpenSettings.externalBrowserApplicationURL(bundleIdentifier: ""))
    }

    func testExternalBrowserApplicationURLReturnsNilForUnknownBundleIdentifier() {
        XCTAssertNil(
            BrowserLinkOpenSettings.externalBrowserApplicationURL(bundleIdentifier: "com.example.does-not-exist")
        )
    }

    func testExternalBrowserApplicationURLResolvesInstalledApplication() throws {
        let url = try XCTUnwrap(
            BrowserLinkOpenSettings.externalBrowserApplicationURL(bundleIdentifier: "com.apple.Safari")
        )
        XCTAssertTrue(url.path.hasSuffix(".app"))
    }

    func testOpenExternallyFallsBackToSystemOpenForUnknownBundleIdentifier() {
        defaults.set("com.example.does-not-exist", forKey: BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey)
        let workspace = BrowserExternalOpenRecordingWorkspace()
        let url = try! XCTUnwrap(URL(string: "https://example.com"))

        let opened = BrowserLinkOpenSettings.openExternally(url, defaults: defaults, workspace: workspace)

        XCTAssertTrue(opened)
        XCTAssertEqual(workspace.openedURLs, [url])
        XCTAssertTrue(workspace.openedWithApplicationURLs.isEmpty)
    }

    func testOpenExternallyLaunchesResolvedApplicationForKnownBundleIdentifier() throws {
        defaults.set("com.apple.Safari", forKey: BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey)
        let workspace = BrowserExternalOpenRecordingWorkspace()
        workspace.applicationURLOverride = URL(fileURLWithPath: "/Applications/Safari.app")
        let url = try XCTUnwrap(URL(string: "https://example.com"))

        let opened = BrowserLinkOpenSettings.openExternally(url, defaults: defaults, workspace: workspace)

        XCTAssertTrue(opened)
        XCTAssertTrue(workspace.openedURLs.isEmpty)
        XCTAssertEqual(workspace.openedWithApplicationURLs.map(\.0), [url])
        XCTAssertEqual(workspace.openedWithApplicationURLs.map(\.1), [workspace.applicationURLOverride])
    }

    func testOpenExternallyKeepsNonWebSchemesOnSystemHandlerEvenWithPreferredBrowser() throws {
        defaults.set("com.apple.Safari", forKey: BrowserLinkOpenSettings.externalBrowserBundleIdentifierKey)
        let workspace = BrowserExternalOpenRecordingWorkspace()
        workspace.applicationURLOverride = URL(fileURLWithPath: "/Applications/Safari.app")
        let mailto = try XCTUnwrap(URL(string: "mailto:someone@example.com"))
        let deepLink = try XCTUnwrap(URL(string: "slack://open?team=T1"))

        XCTAssertTrue(BrowserLinkOpenSettings.openExternally(mailto, defaults: defaults, workspace: workspace))
        XCTAssertTrue(BrowserLinkOpenSettings.openExternally(deepLink, defaults: defaults, workspace: workspace))

        XCTAssertEqual(workspace.openedURLs, [mailto, deepLink])
        XCTAssertTrue(workspace.openedWithApplicationURLs.isEmpty)
    }
}

private final class BrowserExternalOpenRecordingWorkspace: NSWorkspace {
    var openedURLs: [URL] = []
    var openedWithApplicationURLs: [(URL, URL)] = []
    var applicationURLOverride: URL?

    override func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }

    override func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        applicationURLOverride
    }

    override func open(
        _ urls: [URL],
        withApplicationAt applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)? = nil
    ) {
        for url in urls {
            openedWithApplicationURLs.append((url, applicationURL))
        }
    }
}


final class BrowserNavigableURLResolutionTests: XCTestCase {
    func testResolvesFileSchemeAsNavigableURL() throws {
        let resolved = try XCTUnwrap(resolveBrowserNavigableURL("file:///tmp/programa-local-test.html"))
        XCTAssertTrue(resolved.isFileURL)
        XCTAssertEqual(resolved.path, "/tmp/programa-local-test.html")
    }

    func testRejectsNonWebNonFileScheme() {
        XCTAssertNil(resolveBrowserNavigableURL("mailto:test@example.com"))
        XCTAssertNil(resolveBrowserNavigableURL("ftp://example.com/file.html"))
    }

    func testRejectsHostOnlyFileURL() {
        XCTAssertNil(resolveBrowserNavigableURL("file://example.html"))
    }
}


final class BrowserReadAccessURLTests: XCTestCase {
    func testUsesParentDirectoryForFileURL() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = tempRoot.appendingPathComponent("BrowserReadAccessURLTests-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("sample.html")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<html></html>".write(to: file, atomically: true, encoding: .utf8)

        let readAccessURL = try XCTUnwrap(browserReadAccessURL(forLocalFileURL: file))
        XCTAssertEqual(readAccessURL.standardizedFileURL, dir.standardizedFileURL)
    }

    func testUsesDirectoryURLWhenTargetIsDirectory() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = tempRoot.appendingPathComponent("BrowserReadAccessURLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let readAccessURL = try XCTUnwrap(browserReadAccessURL(forLocalFileURL: dir))
        XCTAssertEqual(readAccessURL.standardizedFileURL, dir.standardizedFileURL)
    }

    func testUsesParentDirectoryWhenFileDoesNotExist() throws {
        let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).html")
        let readAccessURL = try XCTUnwrap(browserReadAccessURL(forLocalFileURL: missing))
        XCTAssertEqual(readAccessURL.standardizedFileURL, missing.deletingLastPathComponent().standardizedFileURL)
    }

    func testReturnsNilForHostOnlyFileURL() throws {
        let hostOnly = try XCTUnwrap(URL(string: "file://example.html"))
        XCTAssertNil(browserReadAccessURL(forLocalFileURL: hostOnly))
    }
}


final class BrowserExternalNavigationSchemeTests: XCTestCase {
    func testCustomAppSchemesOpenExternally() throws {
        let discord = try XCTUnwrap(URL(string: "discord://login/one-time?token=abc"))
        let slack = try XCTUnwrap(URL(string: "slack://open"))
        let zoom = try XCTUnwrap(URL(string: "zoommtg://zoom.us/join"))
        let mailto = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertTrue(browserShouldOpenURLExternally(discord))
        XCTAssertTrue(browserShouldOpenURLExternally(slack))
        XCTAssertTrue(browserShouldOpenURLExternally(zoom))
        XCTAssertTrue(browserShouldOpenURLExternally(mailto))
    }

    func testEmbeddedBrowserSchemesStayInWebView() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        let http = try XCTUnwrap(URL(string: "http://example.com"))
        let about = try XCTUnwrap(URL(string: "about:blank"))
        let data = try XCTUnwrap(URL(string: "data:text/plain,hello"))
        let file = try XCTUnwrap(URL(string: "file:///tmp/programa-local-test.html"))
        let blob = try XCTUnwrap(URL(string: "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"))
        let javascript = try XCTUnwrap(URL(string: "javascript:void(0)"))
        let webkitInternal = try XCTUnwrap(URL(string: "applewebdata://local/page"))

        XCTAssertFalse(browserShouldOpenURLExternally(https))
        XCTAssertFalse(browserShouldOpenURLExternally(http))
        XCTAssertFalse(browserShouldOpenURLExternally(about))
        XCTAssertFalse(browserShouldOpenURLExternally(data))
        XCTAssertFalse(browserShouldOpenURLExternally(file))
        XCTAssertFalse(browserShouldOpenURLExternally(blob))
        XCTAssertFalse(browserShouldOpenURLExternally(javascript))
        XCTAssertFalse(browserShouldOpenURLExternally(webkitInternal))
    }
}


final class BrowserHostWhitelistTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserHostWhitelistTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEmptyWhitelistAllowsAll() {
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
    }

    func testExactMatch() {
        defaults.set("localhost\n127.0.0.1", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testExactMatchIsCaseInsensitive() {
        defaults.set("LocalHost", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("LOCALHOST", defaults: defaults))
    }

    func testWildcardSuffix() {
        defaults.set("*.localtest.me", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localtest.me", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testWildcardIsCaseInsensitive() {
        defaults.set("*.Example.COM", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.example.com", defaults: defaults))
    }

    func testBlankLinesAndWhitespaceIgnored() {
        defaults.set("  localhost  \n\n  127.0.0.1  \n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testMixedExactAndWildcard() {
        defaults.set("localhost\n127.0.0.1\n*.local.dev", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.local.dev", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("github.com", defaults: defaults))
    }

    func testDefaultWhitelistIsEmpty() {
        let patterns = BrowserLinkOpenSettings.hostWhitelist(defaults: defaults)
        XCTAssertTrue(patterns.isEmpty)
    }

    func testWildcardRequiresDotBoundary() {
        defaults.set("*.example.com", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("badexample.com", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com.evil", defaults: defaults))
    }

    func testWhitelistNormalizesSchemesPortsAndTrailingDots() {
        defaults.set("https://LOCALHOST:3000/path\n*.Example.COM:443", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost.", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("api.example.com", defaults: defaults))
    }

    func testInvalidWhitelistEntriesDoNotImplicitlyAllowAll() {
        defaults.set("http://\n*.\n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testUnicodeWhitelistEntryMatchesPunycodeHost() {
        defaults.set("b\u{00FC}cher.example", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("xn--bcher-kva.example", defaults: defaults))
    }
}


final class BrowserOmnibarFocusPolicyTests: XCTestCase {
    func testReacquiresFocusWhenOmnibarStillWantsFocusAndNextResponderIsNotAnotherTextField() {
        XCTAssertTrue(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: true,
                nextResponderIsOtherTextField: false
            )
        )
    }

    func testDoesNotReacquireFocusWhenAnotherTextFieldAlreadyTookFocus() {
        XCTAssertFalse(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: true,
                nextResponderIsOtherTextField: true
            )
        )
    }

    func testDoesNotReacquireFocusWhenOmnibarNoLongerWantsFocus() {
        XCTAssertFalse(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: false,
                nextResponderIsOtherTextField: false
            )
        )
    }
}


private final class FailingBrowserDownloadFileManager: FileManager, @unchecked Sendable {
    let moveError = NSError(
        domain: "BrowserDownloadFinalizationTests.Move",
        code: 41
    )

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw moveError
    }
}

final class BrowserDownloadFinalizationTests: XCTestCase {
    func testReadyCallbackObservesTheDownloadAtItsFinalDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BrowserDownloadFinalizationTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("temporary-download", isDirectory: false)
        let destinationURL = root.appendingPathComponent("saved-download", isDirectory: false)
        try Data("download contents".utf8).write(to: sourceURL)
        var readyCount = 0
        var failures: [Error] = []

        BrowserDownloadDelegate.finalizeDownload(
            from: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            onReady: {
                readyCount += 1
                XCTAssertTrue(
                    fileManager.fileExists(atPath: destinationURL.path),
                    "Download readiness must mean the file is already available at its final destination"
                )
                XCTAssertFalse(
                    fileManager.fileExists(atPath: sourceURL.path),
                    "Download readiness must not expose the temporary file as an alternate copy"
                )
            },
            onFailure: { failures.append($0) }
        )

        XCTAssertEqual(readyCount, 1)
        XCTAssertTrue(failures.isEmpty)
    }

    func testMoveFailureReportsFailureAndRetainsTheTemporaryDownload() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BrowserDownloadFinalizationTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("temporary-download", isDirectory: false)
        let destinationURL = root
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("saved-download", isDirectory: false)
        let sourceContents = Data("download contents".utf8)
        try sourceContents.write(to: sourceURL)
        var readyCount = 0
        var failures: [Error] = []

        BrowserDownloadDelegate.finalizeDownload(
            from: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            onReady: { readyCount += 1 },
            onFailure: { failures.append($0) }
        )

        XCTAssertEqual(readyCount, 0, "A download that never reached its destination must not be announced as ready")
        XCTAssertEqual(failures.count, 1, "A failed move must surface exactly one download failure")
        XCTAssertTrue(
            fileManager.fileExists(atPath: sourceURL.path),
            "A failed move must retain the completed temporary download for recovery"
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceContents)
        let failure = try XCTUnwrap(failures.first as? BrowserDownloadFinalizationError)
        XCTAssertEqual(failure.retainedTempURL, sourceURL)
    }

    func testMoveFailurePreservesTheOriginalErrorAndRetainedTemporaryURL() throws {
        let fileManager = FailingBrowserDownloadFileManager()
        let sourceURL = URL(fileURLWithPath: "/unused/temporary-download", isDirectory: false)
        let destinationURL = URL(fileURLWithPath: "/unused/saved-download", isDirectory: false)
        var readyCount = 0
        var failures: [Error] = []

        BrowserDownloadDelegate.finalizeDownload(
            from: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            onReady: { readyCount += 1 },
            onFailure: { failures.append($0) }
        )

        XCTAssertEqual(readyCount, 0, "A failed move must never announce a download as ready")
        XCTAssertEqual(failures.count, 1, "A failed move must be reported as one finalization failure")
        let failure = try XCTUnwrap(failures.first as? BrowserDownloadFinalizationError)
        XCTAssertTrue(
            (failure.moveError as NSError) === fileManager.moveError,
            "The finalization error must preserve the exact move failure for diagnostics"
        )
        XCTAssertEqual(failure.retainedTempURL, sourceURL)
    }
}
