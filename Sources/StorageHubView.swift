import AppKit
import SwiftUI

struct SidebarStorageButton: View {
    @ObservedObject private var model = StorageHubModel.shared
    @State private var isPopoverPresented = false
    @State private var window: NSWindow?
    @State private var clientID = UUID()
    private let title = String(localized: "storage.title", defaultValue: "Storage")
    private let buttonSize = SidebarFooterControlLayout.buttonSize

    var body: some View {
        Button { isPopoverPresented.toggle() } label: {
            Image(systemName: "internaldrive")
                .symbolRenderingMode(.monochrome)
                .symbolRasterSize(11, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented, preferredEdge: .maxX, detachedGap: 4
        ) {
            StorageHubView(model: model)
        })
        .background(StorageWindowResolver { resolvedWindow in
            window = resolvedWindow
            consumeOpenRequest()
        })
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SidebarStorageButton")
        .onChange(of: model.requestedWindowID) { _, _ in consumeOpenRequest() }
        .onChange(of: isPopoverPresented) { _, presented in
            if presented { model.opened(client: clientID) }
            else { model.closed(client: clientID) }
        }
        .onDisappear { model.closed(client: clientID) }
    }

    private func consumeOpenRequest() {
        guard let window, model.consumeOpenRequest(window: window) else { return }
        isPopoverPresented = true
    }
}

private struct StorageWindowResolver: NSViewRepresentable {
    let resolved: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.resolved = resolved
        return view
    }
    func updateNSView(_ view: ResolverView, context: Context) { view.resolved = resolved }

    final class ResolverView: NSView {
        var resolved: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                resolved?(window)
            }
        }
    }
}

struct StorageHubView: View {
    @ObservedObject var model: StorageHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "storage.title", defaultValue: "Storage"))
                .font(.system(size: 12, weight: .semibold))
            if let capacity = model.capacity {
                Text(String(localized: "storage.capacity", defaultValue: "\(bytes(capacity.availableBytes)) free of \(bytes(capacity.totalBytes))"))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "storage.capacityUnavailable", defaultValue: "Free space is unavailable."))
                    .foregroundStyle(.secondary)
            }
            if model.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "storage.working", defaultValue: "Checking storage…"))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let preview = model.preview {
                        confirmation(preview)
                    } else {
                        liveSessions
                        Divider()
                        if let snapshot = model.snapshot { categories(snapshot) }
                        if let result = model.result { outcome(result) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .accessibilityIdentifier("StorageHubView")
    }

    @ViewBuilder
    private var liveSessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "storage.liveSessions", defaultValue: "Live sessions"))
                .fontWeight(.medium)
            if model.liveSessions.isEmpty {
                Text(String(localized: "storage.liveSessions.empty", defaultValue: "No open sessions."))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.liveSessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: session.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(verbatim: session.isMeasured
                            ? (session.sizePartial ? "~" : "") + bytes(session.sizeBytes)
                            : String(localized: "storage.liveSessions.measuring", defaultValue: "Measuring…"))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if !session.heavyFolders.isEmpty {
                        Text(verbatim: session.heavyFolders.map { $0.name + " " + bytes($0.bytes) }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(session.path)
            }
        }
    }

    @ViewBuilder
    private func categories(_ snapshot: StorageHubSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "storage.worktrees", defaultValue: "Worktrees"))
                    .fontWeight(.medium)
                Spacer()
                cleanButton(disabled: snapshot.worktreePreview.removed.isEmpty) { model.prepareClean() }
            }
            Text(String(localized: "storage.worktreeSummary", defaultValue: "\(snapshot.worktreePreview.removed.count) removable (\(bytes(snapshot.worktreePreview.reclaimedBytes))); \(snapshot.worktreePreview.kept.count) kept"))
                .foregroundStyle(.secondary)
            if snapshot.worktrees.contains(where: \.sizePartial) {
                Text(String(localized: "storage.partial", defaultValue: "Some sizes are estimates; the scan could not read every file."))
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.worktreePreview.kept, id: \.entry.path) { kept in
                keptRow(name: kept.entry.branch ?? kept.entry.path, reason: StorageHubCopy.reason(kept.reason.code))
            }
        }
        ForEach(StorageCategoryID.allCases, id: \.self) { category in
            let items = snapshot.caches.filter { $0.category == category }
            if !items.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(StorageHubCopy.category(category)).fontWeight(.medium)
                        Spacer()
                        Text(bytes(items.reduce(0) { $0 + $1.sizeBytes }))
                            .foregroundStyle(.secondary)
                        cleanButton(disabled: items.allSatisfy { $0.blocker != nil }) { model.prepareClean(category: category) }
                    }
                    ForEach(items.filter { $0.blocker != nil }, id: \.id) { item in
                        keptRow(name: item.title, reason: StorageHubCopy.reason(item.blocker ?? ""))
                    }
                }
            }
        }
    }

    private func cleanButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(String(localized: "storage.clean", defaultValue: "Clean"), action: action)
            .controlSize(.small)
            .disabled(disabled || model.isRunning)
    }

    private func confirmation(_ preview: StorageCleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "storage.confirm.title", defaultValue: "Remove these items?"))
                .fontWeight(.medium)
            Text(String(localized: "storage.confirm.total", defaultValue: "\(preview.summary.items.count) items, \(bytes(preview.summary.totalBytes)). This cannot be undone."))
            ForEach(Array(preview.summary.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.name + " (" + bytes(item.sizeBytes) + ")")
                    if let path = item.path {
                        Text(verbatim: path).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if preview.summary.items.isEmpty {
                Text(String(localized: "storage.empty", defaultValue: "Nothing to clean."))
            }
            keptItems(preview)
            HStack {
                Button(String(localized: "storage.cancel", defaultValue: "Cancel")) { model.cancelConfirmation() }
                Spacer()
                Button(String(localized: "storage.confirm.remove", defaultValue: "Remove"), role: .destructive) { model.confirmClean() }
                    .disabled(preview.summary.items.isEmpty || model.isRunning)
            }
            .controlSize(.small)
        }
    }

    private func outcome(_ result: StorageCleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(String(localized: "storage.result", defaultValue: "Removed \(result.summary.items.count) items and reclaimed \(bytes(result.worktrees.reclaimedBytes + result.caches.reclaimedBytes))."))
                .fontWeight(.medium)
            ForEach(Array(result.summary.items.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item.path ?? item.name).foregroundStyle(.secondary)
            }
            keptItems(result)
        }
    }

    @ViewBuilder
    private func keptItems(_ outcome: StorageCleanPreview) -> some View {
        ForEach(outcome.worktrees.kept, id: \.entry.path) { kept in
            keptRow(name: kept.entry.branch ?? kept.entry.path, reason: StorageHubCopy.reason(kept.reason.code))
        }
        ForEach(outcome.caches.kept, id: \.item.id) { kept in
            keptRow(name: kept.item.title, reason: StorageHubCopy.reason(kept.reason))
        }
    }

    private func keptRow(name: String, reason: String) -> some View {
        Text(String(localized: "storage.kept", defaultValue: "Kept \(name): \(reason)"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private enum StorageHubCopy {
    static func category(_ category: StorageCategoryID) -> String {
        switch category {
        case .xcode: String(localized: "storage.category.xcode", defaultValue: "Xcode")
        case .android: String(localized: "storage.category.android", defaultValue: "Android")
        case .packages: String(localized: "storage.category.packages", defaultValue: "Package managers")
        }
    }

    static func reason(_ code: String) -> String {
        switch code {
        case "external": String(localized: "storage.reason.external", defaultValue: "Outside the Programa worktree directory")
        case "status_unknown": String(localized: "storage.reason.unknown", defaultValue: "Could not verify safety")
        case "dirty": String(localized: "storage.reason.dirty", defaultValue: "Uncommitted changes")
        case "env_files": String(localized: "storage.reason.env", defaultValue: "Contains environment files")
        case "not_merged": String(localized: "storage.reason.unmerged", defaultValue: "Branch is not merged")
        case "open_in_workspace": String(localized: "storage.reason.open", defaultValue: "Open in a workspace")
        case "process_running": String(localized: "storage.reason.busy", defaultValue: "A process is using this directory")
        case "recently_used": String(localized: "storage.reason.recent", defaultValue: "Recently used")
        case "git_refused": String(localized: "storage.reason.git", defaultValue: "Git refused removal")
        case "manual_only": String(localized: "storage.reason.manual", defaultValue: "Requires manual cleanup")
        default: String(localized: "storage.reason.tool", defaultValue: "Tool reported: \(code)")
        }
    }
}
