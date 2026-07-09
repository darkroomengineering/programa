import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers


/// A ColorPicker that buffers the current colour in `@State` so that dragging
/// the hue wheel never forces a hex round-trip on every frame.  The stored hex
/// is only written once the user commits a value (on SwiftUI's `.onChange`
/// callback), which fires once per drag-end gesture rather than per frame.
///
/// This replaces computed `Binding<Color>` properties whose getter converted a
/// stored hex string to `Color` on every frame, causing the quantisation that
/// made the hue indicator jump (issue #8 / upstream cmux #6761).
struct HexColorPicker: View {
    /// The current hex value from `@AppStorage`, or `nil` when the slot is unset.
    var hex: String?
    /// Colour to show when `hex` is nil or unparseable.
    var fallback: Color
    /// Called with the new hex string whenever the picker value changes.
    var onHexChange: (String) -> Void

    @State private var pickerColor: Color

    init(hex: String?, fallback: Color, onHexChange: @escaping (String) -> Void) {
        self.hex = hex
        self.fallback = fallback
        self.onHexChange = onHexChange
        let initial: Color
        if let hex, let ns = NSColor(hex: hex) {
            initial = Color(nsColor: ns)
        } else {
            initial = fallback
        }
        _pickerColor = State(initialValue: initial)
    }

    var body: some View {
        ColorPicker("", selection: $pickerColor, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 38)
            .onChange(of: pickerColor) { newColor in
                onHexChange(NSColor(newColor).hexString())
            }
            .onChange(of: hex) { newHex in
                // Keep the buffer in sync when the hex is reset externally
                // (e.g. the Reset button sets sidebarSelectionColorHex = nil).
                if let newHex, let ns = NSColor(hex: newHex) {
                    pickerColor = Color(nsColor: ns)
                } else {
                    pickerColor = fallback
                }
            }
    }
}

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }
}

struct SettingsHeaderActionButton: View {
    let title: String
    let helpText: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.34))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help(helpText)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let controlWidth {
                    trailing
                        .frame(width: controlWidth, alignment: .trailing)
                } else {
                    trailing
                }
            }
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsPickerRow<SelectionValue: Hashable, PickerContent: View, ExtraTrailing: View>: View {
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat
    @Binding var selection: SelectionValue
    let pickerContent: PickerContent
    let extraTrailing: ExtraTrailing
    let accessibilityId: String?

    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent,
        @ViewBuilder extraTrailing: () -> ExtraTrailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self._selection = selection
        self.pickerContent = content()
        self.extraTrailing = extraTrailing()
        self.accessibilityId = accessibilityId
    }

    var body: some View {
        SettingsCardRow(title, subtitle: subtitle, controlWidth: controlWidth) {
            HStack(spacing: 6) {
                Picker("", selection: $selection) {
                    pickerContent
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .applyIf(accessibilityId != nil) { $0.accessibilityIdentifier(accessibilityId!) }
                extraTrailing
            }
        }
    }
}

extension SettingsPickerRow where ExtraTrailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent
    ) {
        self.init(title, subtitle: subtitle, controlWidth: controlWidth, selection: selection, accessibilityId: accessibilityId, content: content) {
            EmptyView()
        }
    }
}

private extension View {
    @ViewBuilder
    func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
            .frame(height: 1)
    }
}

struct SettingsCardNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

