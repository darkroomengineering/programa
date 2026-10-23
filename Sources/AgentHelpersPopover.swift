import AppKit
import SwiftUI

enum AgentHelperState: Equatable, Sendable {
    case idle
    case working
    case needsInput
    case done
    case stopped
    case failed

    init(_ taskState: AgentTaskState) {
        switch taskState {
        case .idle: self = .idle
        case .working: self = .working
        case .blocked: self = .needsInput
        case .completed: self = .done
        case .cancelled: self = .stopped
        case .failed: self = .failed
        }
    }

    var label: String {
        switch self {
        case .idle:
            return String(localized: "agentHelpers.state.idle", defaultValue: "Idle")
        case .working:
            return String(localized: "agentHelpers.state.working", defaultValue: "Working")
        case .needsInput:
            return String(localized: "agentHelpers.state.needsInput", defaultValue: "Needs input")
        case .done:
            return String(localized: "agentHelpers.state.done", defaultValue: "Done")
        case .stopped:
            return String(localized: "agentHelpers.state.stopped", defaultValue: "Stopped")
        case .failed:
            return String(localized: "agentHelpers.state.failed", defaultValue: "Failed")
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .working: return "circle.fill"
        case .needsInput: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .stopped: return .secondary
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}

struct AgentHelperSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    /// The agent type (planner, implementer), shown under a task title that differs from it.
    let role: String?
    let state: AgentHelperState
    let summary: String?
    /// 0-100 while the helper runs, when its program reports one.
    let progress: Int?
    let startedAt: Date
    let endedAt: Date?

    init(_ record: AgentTaskRecord) {
        let fallback = String(localized: "agentHelpers.helper", defaultValue: "Helper")
        let title = [record.task, record.role]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        id = record.id
        self.title = title ?? fallback
        role = record.role.flatMap { $0 == title ? nil : $0 }
        state = AgentHelperState(record.state)
        summary = record.summary
        progress = record.state.isFinished ? nil : record.progress
        startedAt = record.startedAt
        endedAt = record.endedAt
    }

    var isFinished: Bool { endedAt != nil }

    func duration(now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }
}

enum AgentHelpersFormatting {
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func duration(_ interval: TimeInterval) -> String {
        durationFormatter.string(from: interval.rounded(.down)) ?? ""
    }

    /// Reports are markdown; render inline styling, show headings as bold lines, and keep
    /// the line structure as written.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let source = text.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]+(.+?)[ \\t#]*$",
            with: "**$1**",
            options: .regularExpression
        )
        return (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// File name for a report opened in a markdown pane; the pane titles itself from it.
    static func reportFileName(title: String) -> String {
        let cleaned = title.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? Character($0) : " " }
        let words = String(cleaned).split(separator: " ").prefix(8).joined(separator: " ")
        return (words.isEmpty ? "Helper report" : words) + ".md"
    }
}

/// Snapshots one workspace's in-process helpers while the popover is open.
@MainActor
final class AgentHelpersModel: ObservableObject {
    @Published private(set) var running: [AgentHelperSnapshot] = []
    @Published private(set) var finished: [AgentHelperSnapshot] = []
    @Published var expandedHelperId: UUID?

    let workspaceId: UUID
    private weak var workspace: Workspace?
    private var refreshTimer: Timer?

    init(workspaceId: UUID, workspace: Workspace? = nil) {
        self.workspaceId = workspaceId
        self.workspace = workspace
    }

    func start() {
        refresh()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let helpers = AgentSupervisionRegistry.shared
            .helperRecords(workspaceId: workspaceId, surfaceIds: workspace?.panels.keys.map { $0 } ?? [])
            .map(AgentHelperSnapshot.init)
        let nextRunning = helpers.filter { !$0.isFinished }
        // Newest result first: the one you most likely opened the popover for.
        let nextFinished = helpers.filter(\.isFinished).sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        // Assigning an equal array still re-renders every row, which reads as flicker.
        if nextRunning != running { running = nextRunning }
        if nextFinished != finished { finished = nextFinished }
        if let expandedHelperId, !helpers.contains(where: { $0.id == expandedHelperId }) {
            self.expandedHelperId = nil
        }
    }

    func toggle(_ helper: AgentHelperSnapshot) {
        expandedHelperId = expandedHelperId == helper.id ? nil : helper.id
    }

    func clearFinished() {
        for case let panel as TerminalPanel in workspace?.panels.values.map({ $0 }) ?? [] {
            panel.programStatus.removeFinishedChildren()
        }
        AgentSupervisionRegistry.shared.discardFinishedHelpers(workspaceId: workspaceId)
        refresh()
    }

    func copyReport(_ helper: AgentHelperSnapshot) {
        guard let summary = helper.summary, !summary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    /// Writes the report to a temporary file and opens it in a markdown pane beside the
    /// focused pane, so a long report can stay open next to the terminal.
    func openReport(_ helper: AgentHelperSnapshot, in workspace: Workspace) {
        guard let summary = helper.summary, !summary.isEmpty,
              let panelId = workspace.focusedPanelId ?? workspace.sidebarOrderedPanelIds().first else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-helper-reports", isDirectory: true)
            .appendingPathComponent(helper.id.uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(AgentHelpersFormatting.reportFileName(title: helper.title))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try summary.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
            return
        }
        _ = workspace.newMarkdownSplit(from: panelId, orientation: .horizontal, filePath: file.path, focus: true)
    }
}

private struct AgentHelperDurationText: View {
    let helper: AgentHelperSnapshot

    var body: some View {
        if helper.isFinished {
            Text(AgentHelpersFormatting.duration(helper.duration(now: Date())))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(AgentHelpersFormatting.duration(helper.duration(now: context.date)))
            }
        }
    }
}

struct AgentHelpersPopover: View {
    @StateObject private var model: AgentHelpersModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        _model = StateObject(wrappedValue: AgentHelpersModel(workspaceId: workspace.id, workspace: workspace))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.running.isEmpty && model.finished.isEmpty {
                Text(String(localized: "agentHelpers.empty", defaultValue: "No helpers in this workspace."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.running) { helper in
                            helperRow(helper)
                        }
                        if !model.finished.isEmpty {
                            finishedHeader
                            ForEach(model.finished) { helper in
                                helperRow(helper)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 360)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var finishedHeader: some View {
        HStack {
            Text(String(localized: "agentHelpers.finished", defaultValue: "Finished"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "agentHelpers.clearFinished", defaultValue: "Clear")) {
                model.clearFinished()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "agentHelpers.clearFinished.help", defaultValue: "Remove finished helpers from this list"))
        }
        .padding(.horizontal, 8)
        .padding(.top, model.running.isEmpty ? 4 : 10)
        .padding(.bottom, 2)
    }

    private func helperRow(_ helper: AgentHelperSnapshot) -> some View {
        let isExpanded = model.expandedHelperId == helper.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { model.toggle(helper) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: helper.state.symbolName)
                        .imageScale(.small)
                        .foregroundStyle(helper.state.tint)
                        .help(helper.state.label)
                        .accessibilityLabel(helper.state.label)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(helper.title)
                            .lineLimit(isExpanded ? 3 : 1)
                        if let role = helper.role {
                            Text(role)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let progress = helper.progress {
                            ProgressView(value: Double(progress), total: 100)
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                                .accessibilityLabel(String(localized: "agentHelpers.progress", defaultValue: "Progress"))
                                .accessibilityValue("\(progress)%")
                        }
                    }
                    Spacer(minLength: 6)
                    AgentHelperDurationText(helper: helper)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "agentHelpers.toggle.hint", defaultValue: "Shows or hides the report"))

            if isExpanded {
                reportPreview(helper)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isExpanded ? Color.primary.opacity(0.05) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func reportPreview(_ helper: AgentHelperSnapshot) -> some View {
        if let summary = helper.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(AgentHelpersFormatting.inlineMarkdown(summary))
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button(String(localized: "agentHelpers.copyReport", defaultValue: "Copy")) {
                        model.copyReport(helper)
                    }
                    Button(String(localized: "agentHelpers.openReport", defaultValue: "Open Report")) {
                        model.openReport(helper, in: workspace)
                    }
                }
                .controlSize(.small)
            }
            .padding(.leading, 22)
        } else {
            Text(helper.isFinished
                ? String(localized: "agentHelpers.report.none", defaultValue: "This helper finished without a report.")
                : String(localized: "agentHelpers.report.pending", defaultValue: "The report appears here when this helper finishes."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }
}
