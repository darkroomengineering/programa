import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import Bonsplit
import IOSurface
import UniformTypeIdentifiers

// MARK: - GhosttyNSView + Drag & Drop
//
// Drag-and-drop handling for GhosttyNSView: shell-escaping helpers, drop
// plan resolution, dropped-file/pasteboard insertion, and the
// NSDraggingDestination overrides.
//
extension GhosttyNSView {

    static func dropPlanForTesting(pasteboard: NSPasteboard) -> DropPlan {
        switch TerminalPasteboardPlanner.plan(pasteboard: pasteboard, mode: .drop) {
        case .insertText(let text):
            return .insertText(text)
        case .reject:
            return .reject
        }
    }

    func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
        insertPlannedTransfer(TerminalPasteboardPlanner.plan(fileURLs: urls))
    }

    @discardableResult
    func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        insertPlannedTransfer(
            TerminalPasteboardPlanner.plan(pasteboard: pasteboard, mode: .drop)
        )
    }

    @discardableResult
    private func insertPlannedTransfer(
        _ insertion: TerminalPasteboardInsertion
    ) -> Bool {
        switch insertion {
        case .reject:
            return false
        case .insertText(let text):
            terminalSurface?.sendText(text)
            return true
        }
    }

#if DEBUG
    @discardableResult
    func debugSimulateFileDrop(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        let pbName = NSPasteboard.Name("programa.debug.drop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pbName)
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        return insertDroppedPasteboard(pasteboard)
    }

    func debugRegisteredDropTypes() -> [String] {
        registeredDraggedTypes.map(\.rawValue)
    }
#endif

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        dlog("terminal.draggingEntered surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        dlog("terminal.draggingUpdated surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        #if DEBUG
        dlog("terminal.fileDrop surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        return insertDroppedPasteboard(sender.draggingPasteboard)
    }
}
