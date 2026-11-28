import SwiftUI

@main struct ProgramaApp: App {
    var body: some Scene {
        WindowGroup {
            ProgramaHome()
        }
    }
}

private struct ProgramaHome: View {
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedTask") private var selectedTask: String?
    @State private var store = CompanionStore()
    @State private var path: [UUID] = []
    @State private var showComposer = false
    @State private var showForget = false
    @State private var restoredSelection = false

    private struct InboxActivity: Equatable {
        let scene: ScenePhase
        let inboxVisible: Bool
        let paired: Bool
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch store.connection {
                case .loading:
                    ProgressView()
                case .unpaired, .pairing:
                    PairMacView(store: store)
                case let .online(mac), let .offline(mac, _):
                    inbox(mac)
                }
            }
            .navigationTitle(String(localized: "thread.role.programa", defaultValue: "Programa"))
            .navigationDestination(for: UUID.self) { id in
                ConversationView(store: store, jobID: id)
            }
        }
        .task(id: InboxActivity(scene: scenePhase, inboxVisible: path.isEmpty, paired: store.connection.mac != nil)) {
            switch scenePhase {
            case .active:
                await store.launch()
                if !restoredSelection, store.connection.mac != nil {
                    restoredSelection = true
                    if path.isEmpty, let selectedTask, let id = UUID(uuidString: selectedTask) {
                        path = [id]
                    }
                }
                if path.isEmpty { await store.refreshInbox() }
            case .background:
                await store.suspend()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: path) { _, path in
            selectedTask = path.last?.uuidString
        }
        .sheet(isPresented: $showComposer) {
            NewTaskView(store: store) { job in
                showComposer = false
                path.append(job.id)
            }
        }
        .confirmationDialog(
            String(localized: "devices.forgetTitle", defaultValue: "Forget this Mac?"),
            isPresented: $showForget,
            titleVisibility: .visible
        ) {
            Button(String(localized: "devices.forget", defaultValue: "Forget Mac"), role: .destructive) {
                Task {
                    await store.forgetMac()
                    selectedTask = nil
                    path.removeAll()
                }
            }
        } message: {
            Text(String(localized: "devices.forgetMessage", defaultValue: "Tasks stay on the Mac. You can pair with it again any time."))
        }
    }

    private func inbox(_ mac: PairedMac) -> some View {
        List {
            if case let .offline(_, issue) = store.connection {
                Section {
                    Text(issue.label).foregroundStyle(.secondary)
                    Button(String(localized: "common.retry", defaultValue: "Try Again")) {
                        Task { await store.refresh() }
                    }
                }
            }
            if !store.jobs.isEmpty {
                ForEach(store.jobs) { job in
                    NavigationLink(value: job.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title).font(.headline).lineLimit(2)
                            HStack {
                                if let repo = store.repositories.first(where: { $0.id == job.repositoryID }) {
                                    Text(repo.name).lineLimit(1)
                                }
                                Spacer()
                                Text(job.state.label)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if store.jobs.isEmpty, case .online = store.connection {
                ContentUnavailableView(
                    String(localized: "inbox.empty.title", defaultValue: "No Tasks Yet"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(emptyInboxDescription)
                )
                .allowsHitTesting(false)
            }
        }
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(role: .destructive) { showForget = true } label: {
                        Label(String(localized: "devices.forget", defaultValue: "Forget Mac"), systemImage: "link.badge.minus")
                    }
                } label: {
                    Label(mac.name, systemImage: "desktopcomputer")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showComposer = true } label: {
                    Label(String(localized: "task.new", defaultValue: "New Task"), systemImage: "square.and.pencil")
                }
                .disabled(store.repositories.isEmpty)
            }
        }
    }

    private var emptyInboxDescription: String {
        if store.repositories.isEmpty {
            String(localized: "inbox.empty.repositories", defaultValue: "Add a repository in Programa on your Mac to start a task.")
        } else {
            String(localized: "inbox.empty.description", defaultValue: "Start a task to work on a repository from your Mac.")
        }
    }
}
