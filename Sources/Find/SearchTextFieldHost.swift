import AppKit
import Bonsplit
import SwiftUI

enum SearchTextFieldFocusSelection: Equatable {
    case preserve
    case caretAtEnd
}

/// AppKit owner for terminal find fields.
/// SwiftUI owns the surrounding controls while this host owns responder and IME behavior.
struct SearchTextFieldHost: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let accessibilityIdentifier: String
    let focusNotificationName: Notification.Name
    let shouldApplyFocusNotification: (Notification) -> Bool
    let canApplyFocusRequest: () -> Bool
    let focusSelection: SearchTextFieldFocusSelection
    let debugContext: String?
    let onFieldDidFocus: () -> Void
    let onEscape: (NSTextField) -> Void
    let onReturn: (_ isShift: Bool) -> Void

    final class NativeTextField: NSTextField {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextFieldHost
        var isProgrammaticMutation = false
        var isFocusRequestPending = false
        weak var parentField: NativeTextField?
        private var focusObserver: NSObjectProtocol?
        private var observedFocusNotificationName: Notification.Name?

        init(parent: SearchTextFieldHost) {
            self.parent = parent
        }

        deinit {
            removeFocusObserver()
        }

        func installFocusObserver(for field: NativeTextField) {
            guard observedFocusNotificationName != parent.focusNotificationName else { return }
            removeFocusObserver()
            observedFocusNotificationName = parent.focusNotificationName
            focusObserver = NotificationCenter.default.addObserver(
                forName: parent.focusNotificationName,
                object: nil,
                queue: .main
            ) { [weak field, weak self] notification in
                guard let self, let field else { return }
                guard self.parent.shouldApplyFocusNotification(notification) else { return }
                guard self.parent.canApplyFocusRequest() else { return }
                guard let window = field.window else { return }
                let firstResponder = window.firstResponder
                let alreadyFocused = self.isFirstResponder(field, in: window)
#if DEBUG
                if let debugContext = self.parent.debugContext {
                    dlog(
                        "find.nativeField.searchFocusNotification \(debugContext) " +
                        "alreadyFocused=\(alreadyFocused) firstResponder=\(String(describing: firstResponder))"
                    )
                }
#endif
                guard !alreadyFocused else { return }
                let result = self.focus(field, in: window)
#if DEBUG
                if let debugContext = self.parent.debugContext {
                    dlog(
                        "find.nativeField.searchFocusApply \(debugContext) " +
                        "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
                    )
                }
#endif
            }
        }

        func removeFocusObserver() {
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
                self.focusObserver = nil
            }
            observedFocusNotificationName = nil
        }

        func synchronizeText(in field: NativeTextField) {
            if let editor = field.currentEditor() as? NSTextView {
                guard editor.string != parent.text, !editor.hasMarkedText() else { return }
                isProgrammaticMutation = true
                defer { isProgrammaticMutation = false }
                editor.string = parent.text
                field.stringValue = parent.text
            } else if field.stringValue != parent.text {
                isProgrammaticMutation = true
                defer { isProgrammaticMutation = false }
                field.stringValue = parent.text
            }
        }

        func requestFocusIfNeeded(for field: NativeTextField) {
            guard let window = field.window else { return }
            guard parent.isFocused,
                  parent.canApplyFocusRequest(),
                  !isFirstResponder(field, in: window),
                  !isFocusRequestPending else { return }

            isFocusRequestPending = true
            DispatchQueue.main.async { [weak field, weak self] in
                guard let self else { return }
                self.isFocusRequestPending = false
                guard self.parent.isFocused, self.parent.canApplyFocusRequest() else { return }
                guard let field, let window = field.window else { return }
                guard !self.isFirstResponder(field, in: window) else { return }
                _ = self.focus(field, in: window)
            }
        }

        @discardableResult
        private func focus(_ field: NativeTextField, in window: NSWindow) -> Bool {
            guard window.makeFirstResponder(field) else { return false }
            guard parent.focusSelection == .caretAtEnd else { return true }
            DispatchQueue.main.async { [weak field] in
                guard let field,
                      let editor = field.currentEditor() as? NSTextView else { return }
                let end = field.stringValue.utf16.count
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
            return true
        }

        private func isFirstResponder(_ field: NativeTextField, in window: NSWindow) -> Bool {
            let firstResponder = window.firstResponder
            return firstResponder === field ||
                field.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === field
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
#if DEBUG
            if let debugContext = parent.debugContext {
                dlog("find.nativeField.beginEditing \(debugContext)")
            }
#endif
            parent.onFieldDidFocus()
            guard !parent.isFocused else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
#if DEBUG
            if let debugContext = parent.debugContext {
                dlog("find.nativeField.endEditing \(debugContext)")
            }
#endif
            guard parent.isFocused else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = false
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                guard !textView.hasMarkedText() else { return false }
                guard let field = control as? NSTextField else { return false }
                parent.onEscape(field)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                parent.onReturn(isShift)
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NativeTextField {
        let field = NativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "search.placeholder", defaultValue: "Search")
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        context.coordinator.parentField = field
        context.coordinator.installFocusObserver(for: field)
        return field
    }

    func updateNSView(_ nsView: NativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        context.coordinator.installFocusObserver(for: nsView)
        context.coordinator.synchronizeText(in: nsView)
        context.coordinator.requestFocusIfNeeded(for: nsView)
    }

    static func dismantleNSView(_ nsView: NativeTextField, coordinator: Coordinator) {
        coordinator.removeFocusObserver()
        nsView.delegate = nil
        coordinator.parentField = nil
    }
}
