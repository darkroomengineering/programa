import AppKit
import Bonsplit

final class BrowserDropZoneOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct BrowserPortalSearchOverlayConfiguration {
    let panelId: UUID
    let searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void
}

struct BrowserPaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
}

struct BrowserPaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    static func decode(from pasteboard: NSPasteboard) -> BrowserPaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data) -> BrowserPaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        return BrowserPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId
        )
    }
}

struct BrowserPaneSplitTarget: Equatable {
    let orientation: SplitOrientation
    let insertFirst: Bool
}

enum BrowserPaneDropAction: Equatable {
    case noOp
    case move(
        tabId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID,
        splitTarget: BrowserPaneSplitTarget?
    )
}

enum BrowserPaneDropRouting {
    private static let padding: CGFloat = 4

    private static func fullPaneSize(for slotSize: CGSize, topChromeHeight: CGFloat) -> CGSize {
        CGSize(width: slotSize.width, height: slotSize.height + max(0, topChromeHeight))
    }

    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, fullPaneSize.width * edgeRatio)
        let verticalEdge = max(80, fullPaneSize.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > fullPaneSize.width - horizontalEdge {
            return .right
        } else if location.y > fullPaneSize.height - verticalEdge {
            return .top
        } else if location.y < verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        switch zone {
        case .center:
            return CGRect(
                x: padding,
                y: padding,
                width: fullPaneSize.width - padding * 2,
                height: fullPaneSize.height - padding * 2
            )
        case .left:
            return CGRect(
                x: padding,
                y: padding,
                width: fullPaneSize.width / 2 - padding,
                height: fullPaneSize.height - padding * 2
            )
        case .right:
            return CGRect(
                x: fullPaneSize.width / 2,
                y: padding,
                width: fullPaneSize.width / 2 - padding,
                height: fullPaneSize.height - padding * 2
            )
        case .top:
            return CGRect(
                x: padding,
                y: fullPaneSize.height / 2,
                width: fullPaneSize.width - padding * 2,
                height: fullPaneSize.height / 2 - padding
            )
        case .bottom:
            return CGRect(
                x: padding,
                y: padding,
                width: fullPaneSize.width - padding * 2,
                height: fullPaneSize.height / 2 - padding
            )
        }
    }

    static func action(
        for transfer: BrowserPaneDragTransfer,
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BrowserPaneDropAction? {
        if zone == .center, transfer.sourcePaneId == target.paneId.id {
            return .noOp
        }

        let splitTarget: BrowserPaneSplitTarget?
        switch zone {
        case .center:
            splitTarget = nil
        case .left:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: true)
        case .right:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: false)
        case .top:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: true)
        case .bottom:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: false)
        }

        return .move(
            tabId: transfer.tabId,
            targetWorkspaceId: target.workspaceId,
            targetPane: target.paneId,
            splitTarget: splitTarget
        )
    }
}

final class BrowserPaneDropTargetView: NSView {
    weak var slotView: WindowBrowserSlotView?
    var dropContext: BrowserPaneDropContext?
    private var activeZone: DropZone?
#if DEBUG
    private var lastHitTestSignature: String?
#endif

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes) else { return false }
        guard let eventType else { return false }

        switch eventType {
        case .cursorUpdate,
             .mouseEntered,
             .mouseExited,
             .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .appKitDefined,
             .applicationDefined,
             .systemDefined,
             .periodic:
            return true
        default:
            return false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), dropContext != nil else { return nil }

        let pasteboardTypes = NSPasteboard(name: .drag).types
        let eventType = NSApp.currentEvent?.type
        let capture = Self.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType
        )
#if DEBUG
        logHitTestDecision(capture: capture, pasteboardTypes: pasteboardTypes, eventType: eventType)
#endif
        return capture ? self : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragState(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragState(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDragState(phase: "exited")
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            clearDragState(phase: "perform.clear")
        }

        guard let dropContext,
              let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess else {
#if DEBUG
            dlog("browser.paneDrop.perform allowed=0 reason=missingTransfer")
#endif
            return false
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )
        guard let action = BrowserPaneDropRouting.action(
            for: transfer,
            target: dropContext,
            zone: zone
        ) else {
#if DEBUG
            dlog(
                "browser.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "reason=noAction zone=\(zone)"
            )
#endif
            return false
        }

        switch action {
        case .noOp:
#if DEBUG
            dlog(
                "browser.paneDrop.perform allowed=1 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(transfer.tabId.uuidString.prefix(5)) action=noop"
            )
#endif
            return true
        case .move(let tabId, let workspaceId, let targetPane, let splitTarget):
            let moved = AppDelegate.shared?.moveBonsplitTab(
                tabId: tabId,
                toWorkspace: workspaceId,
                targetPane: targetPane,
                splitTarget: splitTarget.map { ($0.orientation, $0.insertFirst) },
                focus: true,
                focusWindow: true
            ) ?? false
#if DEBUG
            let splitLabel = splitTarget.map {
                "\($0.orientation.rawValue):\($0.insertFirst ? 1 : 0)"
            } ?? "none"
            dlog(
                "browser.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuidString.prefix(5)) zone=\(zone) pane=\(targetPane.id.uuidString.prefix(5)) " +
                "split=\(splitLabel) moved=\(moved ? 1 : 0)"
            )
#endif
            return moved
        }
    }

    private func updateDragState(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        guard let dropContext,
              let transfer = BrowserPaneDragTransfer.decode(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = BrowserPaneDropRouting.zone(
            for: location,
            in: bounds.size,
            topChromeHeight: slotView?.effectivePaneTopChromeHeight() ?? 0
        )
        activeZone = zone
        slotView?.setPortalDragDropZone(zone)
#if DEBUG
        dlog(
            "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "tab=\(transfer.tabId.uuidString.prefix(5)) zone=\(zone)"
        )
#endif
        return .move
    }

    private func clearDragState(phase: String) {
        guard activeZone != nil else { return }
        activeZone = nil
        slotView?.setPortalDragDropZone(nil)
#if DEBUG
        if let dropContext {
            dlog(
                "browser.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) zone=none"
            )
        }
#endif
    }

#if DEBUG
    private func logHitTestDecision(
        capture: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) {
        let hasTransferType = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        guard hasTransferType || capture else { return }

        let signature = [
            capture ? "1" : "0",
            hasTransferType ? "1" : "0",
            String(describing: dropContext != nil),
            eventType.map { String($0.rawValue) } ?? "nil",
        ].joined(separator: "|")
        guard lastHitTestSignature != signature else { return }
        lastHitTestSignature = signature

        let types = pasteboardTypes?.map(\.rawValue).joined(separator: ",") ?? "-"
        dlog(
            "browser.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) context=\(dropContext != nil ? 1 : 0) " +
            "event=\(eventType.map { String($0.rawValue) } ?? "nil") types=\(types)"
        )
    }
#endif
}
