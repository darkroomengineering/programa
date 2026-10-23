import AppKit
import UniformTypeIdentifiers

/// Custom UTType for tab drag and drop
extension UTType {
    static var tabTransfer: UTType {
        UTType(exportedAs: "com.splittabbar.tabtransfer", conformingTo: .data)
    }
}

/// Represents a single tab in a pane's tab bar (internal representation)
struct TabItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var hasCustomTitle: Bool
    var icon: String?
    var iconImageData: Data?
    var iconAsset: String?
    var kind: String?
    var isDirty: Bool
    var showsNotificationBadge: Bool
    var isLoading: Bool
    var isPinned: Bool
    var customColorHex: String?

    init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        iconAsset: String? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        customColorHex: String? = nil
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.iconAsset = iconAsset
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isPinned = isPinned
        self.customColorHex = customColorHex
    }

    init(from tab: Tab) {
        self.init(
            id: tab.id.id,
            title: tab.title,
            hasCustomTitle: tab.hasCustomTitle,
            icon: tab.icon,
            iconImageData: tab.iconImageData,
            iconAsset: tab.iconAsset,
            kind: tab.kind,
            isDirty: tab.isDirty,
            showsNotificationBadge: tab.showsNotificationBadge,
            isLoading: tab.isLoading,
            isPinned: tab.isPinned,
            customColorHex: tab.customColorHex
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case hasCustomTitle
        case icon
        case iconImageData
        case iconAsset
        case kind
        case isDirty
        case showsNotificationBadge
        case isLoading
        case isPinned
        case customColorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.hasCustomTitle = try c.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.iconImageData = try c.decodeIfPresent(Data.self, forKey: .iconImageData)
        self.iconAsset = try c.decodeIfPresent(String.self, forKey: .iconAsset)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        self.showsNotificationBadge = try c.decodeIfPresent(Bool.self, forKey: .showsNotificationBadge) ?? false
        self.isLoading = try c.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.customColorHex = try c.decodeIfPresent(String.self, forKey: .customColorHex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(hasCustomTitle, forKey: .hasCustomTitle)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(iconImageData, forKey: .iconImageData)
        try c.encodeIfPresent(iconAsset, forKey: .iconAsset)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(isDirty, forKey: .isDirty)
        try c.encode(showsNotificationBadge, forKey: .showsNotificationBadge)
        try c.encode(isLoading, forKey: .isLoading)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(customColorHex, forKey: .customColorHex)
    }
}

extension TabItem {
    /// Localized state names announced as the tab's accessibility value.
    var accessibilityStates: [String] {
        var states: [String] = []
        if isLoading { states.append(BonsplitStrings.tabLoading) }
        if isPinned { states.append(BonsplitStrings.tabPinned) }
        if showsNotificationBadge { states.append(BonsplitStrings.tabUnread) }
        if isDirty { states.append(BonsplitStrings.tabModified) }
        return states
    }
}

/// Transfer data that includes source pane information for cross-pane moves
struct TabTransferData: Codable {
    let tab: TabItem
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    init(tab: TabItem, sourcePaneId: UUID, sourceProcessId: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case tab
        case sourcePaneId
        case sourceProcessId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tab = try container.decode(TabItem.self, forKey: .tab)
        self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
        // Legacy payloads won't include this field. Treat as foreign process to reject cross-instance drops.
        self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tab, forKey: .tab)
        try container.encode(sourcePaneId, forKey: .sourcePaneId)
        try container.encode(sourceProcessId, forKey: .sourceProcessId)
    }

    /// Decodes the payload of the drag in progress, written as data or as a JSON string.
    static func fromDragPasteboard() -> TabTransferData? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)
        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8) {
            return try? JSONDecoder().decode(TabTransferData.self, from: data)
        }
        return nil
    }
}
