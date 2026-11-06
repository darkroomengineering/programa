import AppKit
import SwiftUI
import Darwin

/// Card rows inset their text by this much; headers, footers and dividers align to it.
enum SettingsCardMetrics {
    static let textInset: CGFloat = 14
    static let cornerRadius: CGFloat = 10
}

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.leading, SettingsCardMetrics.textInset)
            .padding(.top, 10)
            .padding(.bottom, -2)
    }
}

struct SettingsSectionFooter: View {
    let paragraphs: [String]
    /// Lands on each paragraph's `Text`, so UI tests find it as a static text.
    let accessibilityIdentifier: String?

    init(_ paragraphs: String..., accessibilityIdentifier: String? = nil) {
        self.paragraphs = paragraphs
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
                    .applyIf(accessibilityIdentifier != nil) { $0.accessibilityIdentifier(accessibilityIdentifier!) }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, SettingsCardMetrics.textInset)
        .padding(.top, -4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            RoundedRectangle(cornerRadius: SettingsCardMetrics.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
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
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        .padding(.horizontal, SettingsCardMetrics.textInset)
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
        Divider()
            .padding(.horizontal, SettingsCardMetrics.textInset)
    }
}

struct SettingsCardNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, SettingsCardMetrics.textInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
