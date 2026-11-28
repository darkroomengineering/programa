import SwiftUI

private struct PromptDraft: Equatable {
    let messageID: UUID
    let jobID: UUID
    let repositoryID: UUID?
    let text: String

    var request: MobileChatRequest {
        if let repositoryID {
            return .start(jobID: jobID, messageID: messageID, repositoryID: repositoryID, prompt: text)
        }
        return .reply(jobID: jobID, messageID: messageID, prompt: text)
    }
}

private enum PromptSubmission {
    case editing
    case sending(PromptDraft)
    case failed(PromptDraft, CompanionIssue)

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    var issue: CompanionIssue? {
        if case let .failed(_, issue) = self { return issue }
        return nil
    }

    func draft(text: String, jobID: UUID? = nil, repositoryID: UUID? = nil) -> PromptDraft {
        if case let .failed(previous, _) = self,
           previous.text == text, previous.repositoryID == repositoryID,
           jobID == nil || previous.jobID == jobID {
            return previous
        }
        return PromptDraft(messageID: UUID(), jobID: jobID ?? UUID(), repositoryID: repositoryID, text: text)
    }
}

private extension String {
    var preparedPrompt: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmitPrompt: Bool {
        !isEmpty && utf8.count <= MobileChatWire.maximumPromptBytes
    }
}

struct NewTaskView: View {
    let store: CompanionStore
    let onStart: (MobileChatJob) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var repositoryID: UUID?
    @State private var prompt = ""
    @State private var submission: PromptSubmission = .editing

    private var selectedRepository: UUID? { repositoryID ?? store.repositories.first?.id }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        String(localized: "task.repository", defaultValue: "Repository"),
                        selection: Binding(get: { selectedRepository }, set: { repositoryID = $0 })
                    ) {
                        ForEach(store.repositories) { repository in
                            Text(repository.name).tag(Optional(repository.id))
                        }
                    }
                    TextField(
                        String(localized: "task.prompt", defaultValue: "What should Programa do?"),
                        text: $prompt,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }
                .disabled(submission.isSending)

                if let issue = submission.issue {
                    Text(issue.label).foregroundStyle(.secondary)
                } else if prompt.preparedPrompt.utf8.count > MobileChatWire.maximumPromptBytes {
                    Text(String(localized: "task.tooLong", defaultValue: "This message is too long. Shorten it and try again."))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "task.new", defaultValue: "New Task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(submission.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submission.isSending {
                        ProgressView()
                            .accessibilityLabel(String(localized: "task.sending", defaultValue: "Sending"))
                    } else {
                        Button(String(localized: "task.start", defaultValue: "Start"), action: send)
                            .disabled(selectedRepository == nil || !prompt.preparedPrompt.canSubmitPrompt)
                    }
                }
            }
        }
        .interactiveDismissDisabled(submission.isSending)
    }

    private func send() {
        let text = prompt.preparedPrompt
        guard text.canSubmitPrompt, let selectedRepository, !submission.isSending else { return }
        let draft = submission.draft(text: text, repositoryID: selectedRepository)
        submission = .sending(draft)
        Task {
            do {
                let job = try await store.submit(draft.request)
                onStart(job)
            } catch {
                submission = .failed(draft, CompanionIssue(error))
            }
        }
    }
}

struct ConversationView: View {
    let store: CompanionStore
    let jobID: UUID

    private enum EarlierHistory {
        case none
        case available
        case loading
        case failed(CompanionIssue)
    }

    private struct LoadedHistory {
        var messages: [MobileChatMessage]
        var earlier: EarlierHistory
        var includesEarlier: Bool
    }

    private enum History {
        case loading
        case failed(CompanionIssue)
        case loaded(LoadedHistory)
    }

    private struct RefreshActivity: Equatable {
        let scene: ScenePhase
        let newReplies: Int
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var history: History = .loading
    @State private var reply = ""
    @State private var submission: PromptSubmission = .editing
    @State private var newReplies = 0

    private var job: MobileChatJob? { store.job(jobID) }

    private var workspaceURL: URL? {
        guard let reference = job?.workspaceReference else { return nil }
        return URL(string: "programa://workspace/\(reference.uuidString.lowercased())")
    }

    var body: some View {
        Group {
            switch history {
            case .loading:
                ProgressView()
            case let .failed(issue):
                ContentUnavailableView {
                    Label(String(localized: "thread.unavailable", defaultValue: "Conversation Unavailable"), systemImage: "exclamationmark.bubble")
                } description: {
                    Text(issue.label)
                } actions: {
                    Button(String(localized: "common.retry", defaultValue: "Try Again")) { newReplies += 1 }
                }
            case let .loaded(page):
                transcript(page)
            }
        }
        .navigationTitle(job?.title ?? String(localized: "thread.title", defaultValue: "Conversation"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let workspaceURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: workspaceURL) {
                        Label(String(localized: "thread.shareMac", defaultValue: "Share Mac Workspace Link"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: RefreshActivity(scene: scenePhase, newReplies: newReplies)) {
            if scenePhase == .active { await watch() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    }

    private func transcript(_ page: LoadedHistory) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    earlierControl(page.earlier)
                    ForEach(page.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if let job, job.state.isActive {
                        HStack(spacing: 10) {
                            ProgressView().accessibilityHidden(true)
                            Text(job.state.label)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .refreshable { await refresh() }
            .onChange(of: page.messages.last?.id) { oldID, newID in
                if oldID != nil, let newID { reader.scrollTo(newID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func earlierControl(_ state: EarlierHistory) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .available:
            Button(String(localized: "thread.older", defaultValue: "Load Earlier Messages"), action: loadEarlier)
        case .loading:
            ProgressView()
                .accessibilityLabel(String(localized: "thread.loadingOlder", defaultValue: "Loading Earlier Messages"))
        case let .failed(issue):
            VStack(alignment: .leading, spacing: 8) {
                Text(issue.label).foregroundStyle(.secondary)
                Button(String(localized: "common.retry", defaultValue: "Try Again"), action: loadEarlier)
            }
        }
    }

    private func messageRow(_ message: MobileChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: message.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let issue = submission.issue {
                Text(issue.label).font(.footnote).foregroundStyle(.secondary)
            } else if case let .offline(_, issue) = store.connection, case .loaded = history {
                Text(issue.label).font(.footnote).foregroundStyle(.secondary)
            } else if reply.preparedPrompt.utf8.count > MobileChatWire.maximumPromptBytes {
                Text(String(localized: "task.tooLong", defaultValue: "This message is too long. Shorten it and try again."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(String(localized: "thread.reply", defaultValue: "Message"), text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.vertical, 10)
                    .disabled(submission.isSending)
                if submission.isSending {
                    ProgressView()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(String(localized: "task.sending", defaultValue: "Sending"))
                } else {
                    Button(action: send) {
                        Label(String(localized: "thread.send", defaultValue: "Send Message"), systemImage: "arrow.up.circle.fill")
                            .font(.title2)
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(job == nil || !reply.preparedPrompt.canSubmitPrompt)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func watch() async {
        await refresh()
        while !Task.isCancelled, let job, job.state.isActive {
            let delay: Duration = if case .offline = store.connection { .seconds(8) } else { .seconds(2) }
            do { try await Task.sleep(for: delay) } catch { return }
            await refresh()
        }
    }

    private func refresh() async {
        do {
            let page = try await store.history(for: jobID)
            if case var .loaded(previous) = history, previous.includesEarlier {
                let incoming = Set(page.messages.map(\.id))
                previous.messages = previous.messages.filter { !incoming.contains($0.id) } + page.messages
                history = .loaded(previous)
            } else {
                history = .loaded(LoadedHistory(
                    messages: page.messages,
                    earlier: page.hasEarlier ? .available : .none,
                    includesEarlier: false
                ))
            }
        } catch is CancellationError {
            return
        } catch {
            if case .loaded = history { return }
            history = .failed(CompanionIssue(error))
        }
    }

    private func loadEarlier() {
        guard case var .loaded(page) = history, let before = page.messages.first?.id else { return }
        if case .loading = page.earlier { return }
        page.earlier = .loading
        page.includesEarlier = true
        history = .loaded(page)
        Task {
            do {
                let older = try await store.history(for: jobID, before: before)
                guard case var .loaded(current) = history else { return }
                let present = Set(current.messages.map(\.id))
                current.messages = older.messages.filter { !present.contains($0.id) } + current.messages
                current.earlier = older.hasEarlier ? .available : .none
                history = .loaded(current)
            } catch {
                guard case var .loaded(current) = history else { return }
                current.earlier = .failed(CompanionIssue(error))
                history = .loaded(current)
            }
        }
    }

    private func send() {
        let text = reply.preparedPrompt
        guard text.canSubmitPrompt, !submission.isSending else { return }
        let draft = submission.draft(text: text, jobID: jobID)
        submission = .sending(draft)
        Task {
            do {
                _ = try await store.submit(draft.request)
                reply = ""
                submission = .editing
                newReplies += 1
            } catch {
                submission = .failed(draft, CompanionIssue(error))
            }
        }
    }
}

private extension MobileChatRole {
    var label: String {
        switch self {
        case .user: String(localized: "thread.role.user", defaultValue: "You")
        case .assistant: String(localized: "thread.role.agent", defaultValue: "Agent")
        case .system: String(localized: "thread.role.programa", defaultValue: "Programa")
        }
    }
}
