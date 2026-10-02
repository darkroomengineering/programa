import AppKit
import SwiftUI

/// Actions the hub performs on a port row. Kept out of the view so they share one path.
@MainActor
enum PortsHubActions {
    /// Test seam: replaces the confirmation alert. Returns true when the user confirms.
    static var confirmStopHandler: ((_ command: String, _ port: Int, _ pid: Int) -> Bool)?

    static func url(forPort port: Int) -> URL? {
        URL(string: "http://localhost:\(port)")
    }

    /// Opens like the sidebar port chips: in a Programa browser split of the owning
    /// workspace when there is one, otherwise in the default browser.
    static func open(port: Int, workspaceId: UUID?) {
        guard let url = url(forPort: port) else { return }
        if let workspaceId,
           let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
           tabManager.openBrowser(
               inWorkspace: workspaceId,
               url: url,
               preferSplitRight: true,
               insertAtEnd: true
           ) != nil {
            return
        }
        BrowserLinkOpenSettings.openExternally(url)
    }

    static func copyURL(port: Int) {
        guard let url = url(forPort: port) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Selects the workspace and focuses the panel that owns the process.
    static func reveal(workspaceId: UUID, panelId: UUID?) {
        guard let appDelegate = AppDelegate.shared,
              let tabManager = appDelegate.tabManagerFor(tabId: workspaceId),
              let workspace = tabManager.workspace(withId: workspaceId) else { return }
        if let windowId = appDelegate.mainWindowContexts.values
            .first(where: { $0.tabManager === tabManager })?.windowId {
            _ = appDelegate.focusMainWindow(windowId: windowId)
        }
        tabManager.selectWorkspace(workspace)
        if let panelId {
            tabManager.focusSurface(tabId: workspaceId, surfaceId: panelId)
        }
    }

    static func confirmStop(command: String, port: Int, pid: Int) -> Bool {
        if let confirmStopHandler { return confirmStopHandler(command, port, pid) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.stopPort.title",
            defaultValue: "Stop \(command) on port \(port)?"
        )
        alert.informativeText = String(
            localized: "dialog.stopPort.message",
            defaultValue: "Programa asks process \(pid) to quit, and force-stops it if it is still running after 3 seconds."
        )
        alert.addButton(withTitle: String(localized: "dialog.stopPort.cancel", defaultValue: "Cancel"))
        alert.addButton(withTitle: String(localized: "dialog.stopPort.confirm", defaultValue: "Stop"))
        // Cancel is the default button so a stray Return never kills a process.
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func stop(command: String, port: Int, pid: Int) {
        guard confirmStop(command: command, port: port, pid: pid) else { return }
        _ = PortsHubStore.shared.stop(pid: pid)
    }
}

struct PortsHubView: View {
    @ObservedObject var store: PortsHubStore

    private static let width: CGFloat = 360
    private static let maxListHeight: CGFloat = 340

    var body: some View {
        let workspaces = store.workspaceSnapshot()
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "ports.hub.title", defaultValue: "Listening Ports"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if workspaces.isEmpty && store.leftovers.isEmpty {
                Text(String(localized: "ports.hub.empty", defaultValue: "Nothing is listening on a port."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(workspaces) { workspace in
                            section(title: workspace.title) {
                                ForEach(workspace.rows) { row in
                                    PortsHubRowView(
                                        port: row.port,
                                        pid: row.pid,
                                        command: row.command,
                                        isStopping: store.stoppingPIDs.contains(row.pid),
                                        onOpen: { PortsHubActions.open(port: row.port, workspaceId: workspace.workspaceId) },
                                        onReveal: {
                                            PortsHubActions.reveal(workspaceId: workspace.workspaceId, panelId: row.panelId)
                                        }
                                    )
                                }
                            }
                        }
                        if !store.leftovers.isEmpty {
                            section(
                                title: String(localized: "ports.hub.leftRunning", defaultValue: "Left running")
                            ) {
                                ForEach(store.leftovers) { leftover in
                                    ForEach(leftover.ports, id: \.self) { port in
                                        PortsHubRowView(
                                            port: port,
                                            pid: leftover.pid,
                                            command: leftover.command,
                                            isStopping: store.stoppingPIDs.contains(leftover.pid),
                                            onOpen: { PortsHubActions.open(port: port, workspaceId: nil) },
                                            onReveal: nil
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: Self.maxListHeight)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .onAppear { store.revalidateLeftovers() }
        .accessibilityIdentifier("PortsHubView")
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
            content()
        }
    }
}

private struct PortsHubRowView: View {
    let port: Int
    let pid: Int
    let command: String
    let isStopping: Bool
    let onOpen: () -> Void
    let onReveal: (() -> Void)?

    private var displayCommand: String {
        command.isEmpty ? String(localized: "ports.hub.unnamedCommand", defaultValue: "process") : command
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: ":\(port)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(displayCommand)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(String(localized: "ports.hub.pid", defaultValue: "pid \(pid)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            iconButton(
                systemName: "safari",
                label: String(localized: "ports.hub.open", defaultValue: "Open in browser"),
                action: onOpen
            )
            iconButton(
                systemName: "doc.on.doc",
                label: String(localized: "ports.hub.copyURL", defaultValue: "Copy URL"),
                action: { PortsHubActions.copyURL(port: port) }
            )
            if let onReveal {
                iconButton(
                    systemName: "arrow.right.circle",
                    label: String(localized: "ports.hub.reveal", defaultValue: "Reveal in workspace"),
                    action: onReveal
                )
            }
            iconButton(
                systemName: isStopping ? "hourglass" : "stop.circle",
                label: isStopping
                    ? String(localized: "ports.hub.stopping", defaultValue: "Stopping")
                    : String(localized: "ports.hub.stop", defaultValue: "Stop"),
                action: { PortsHubActions.stop(command: displayCommand, port: port, pid: pid) }
            )
            .disabled(isStopping)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func iconButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRasterSize(11, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .safeHelp(label)
        .accessibilityLabel(label)
    }
}

/// Sidebar footer button that opens the ports hub. Hidden while nothing is listening.
struct SidebarPortsButton: View {
    @ObservedObject private var store = PortsHubStore.shared
    @State private var isPopoverPresented = false

    private let buttonSize = SidebarFooterControlLayout.buttonSize
    private let iconSize: CGFloat = 11

    var body: some View {
        if store.badgeCount > 0 {
            let title = String(localized: "sidebar.ports.button", defaultValue: "Ports")
            Button {
                if !isPopoverPresented { store.revalidateLeftovers() }
                isPopoverPresented.toggle()
            } label: {
                Image(systemName: "network")
                    .symbolRenderingMode(.monochrome)
                    .symbolRasterSize(iconSize, weight: .medium)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: buttonSize, height: buttonSize, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        Text(verbatim: "\(store.badgeCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 1, y: 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .frame(width: buttonSize, height: buttonSize, alignment: .center)
            .background(ArrowlessPopoverAnchor(
                isPresented: $isPopoverPresented,
                preferredEdge: .maxX,
                detachedGap: 4
            ) {
                PortsHubView(store: store)
            })
            .safeHelp(title)
            .accessibilityLabel(
                String(localized: "sidebar.ports.button.count", defaultValue: "Ports, \(store.badgeCount) listening")
            )
            .accessibilityIdentifier("SidebarPortsButton")
        }
    }
}
