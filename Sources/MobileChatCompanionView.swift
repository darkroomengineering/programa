import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
@Observable
final class MobileChatCompanionModel {
    static let shared = MobileChatCompanionModel()

    struct Invitation {
        let id = UUID()
        let url: URL
        let expiresAt: Date
        let image: NSImage
    }

    enum Enrollment {
        case unpaired
        case openingInvitation
        case invitation(Invitation)
        case cancellingInvitation
        case paired(String)
        case revoking(String)
    }

    struct Connection {
        let id: UUID
        let host: MobileChatHost
        var enrollment: Enrollment
    }

    enum Service {
        case stopped
        case starting
        case running(Connection)
        case stopping
    }

    enum Issue {
        case repository
        case executable
        case start
        case invitation
        case revoke

        var message: String {
            switch self {
            case .repository:
                String(localized: "mobileChat.error.repository", defaultValue: "Choose a Git checkout that Programa can open.")
            case .executable:
                String(localized: "mobileChat.error.executable", defaultValue: "Choose an executable Claude Code binary.")
            case .start:
                String(localized: "mobileChat.error.start", defaultValue: "Programa couldn’t start the iPhone connection. Try again.")
            case .invitation:
                String(localized: "mobileChat.error.invitation", defaultValue: "Programa couldn’t prepare a pairing code. Try again.")
            case .revoke:
                String(localized: "mobileChat.error.revoke", defaultValue: "Programa couldn’t remove access for the paired iPhone. Try again.")
            }
        }
    }

    private struct Repository: Codable {
        let id: UUID
        let checkout: URL
    }

    private struct Configuration: Codable {
        var repository: Repository?
        var repositoryIDs: [String: UUID] = [:]
        var executable: URL?
        var enabled = false
    }

    private static let defaultsKey = "mobileChatCompanion.configuration"
    private let defaults = UserDefaults.standard
    private var configuration: Configuration
    @ObservationIgnored private var jobsByRepository: [UUID: MobileChatJobs] = [:]
    private(set) var service: Service = .stopped
    private(set) var issue: Issue?

    private init() {
        configuration = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
    }

    var checkout: URL? { configuration.repository?.checkout }
    var isOptedIn: Bool { configuration.enabled }
    var executable: URL {
        configuration.executable ?? Self.defaultExecutable
    }

    private static let defaultExecutable: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return locations.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? locations[0]
    }()

    var canChooseRepository: Bool {
        if case .stopped = service { return !configuration.enabled }
        return false
    }

    var canChooseExecutable: Bool {
        if case .stopped = service { return true }
        return false
    }

    func chooseRepository() async {
        guard canChooseRepository,
              let folder = await chooseFile(directory: true) else { return }
        let root = await Self.resolveRepository(folder)
        guard canChooseRepository else { return }
        guard let root else {
            issue = .repository
            return
        }
        if configuration.repository?.checkout != root {
            let id = configuration.repositoryIDs[root.path] ?? UUID()
            configuration.repositoryIDs[root.path] = id
            configuration.repository = Repository(id: id, checkout: root)
            save()
        }
        issue = nil
    }

    func chooseExecutable() async {
        guard canChooseExecutable,
              let program = await chooseFile(directory: false), canChooseExecutable else { return }
        let executable = program.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable.path) else {
            issue = .executable
            return
        }
        configuration.executable = executable
        issue = nil
        save()
    }

    func resumeIfEnabled() async {
        guard configuration.enabled else { return }
        await enable()
    }

    func enable() async {
        guard case .stopped = service else { return }
        guard let repository = configuration.repository else {
            issue = .repository
            return
        }
        let program = executable
        guard FileManager.default.isExecutableFile(atPath: program.path) else {
            issue = .executable
            return
        }
        service = .starting
        issue = nil
        guard await Self.resolveRepository(repository.checkout) == repository.checkout else {
            service = .stopped
            issue = .repository
            return
        }
        let id = UUID()
        do {
            let jobs: MobileChatJobs
            if let existing = jobsByRepository[repository.id] {
                try await existing.updateClaudeExecutable(program)
                jobs = existing
            } else {
                jobs = try await Self.openJobs(repository: repository, program: program)
                jobsByRepository[repository.id] = jobs
            }
            let host = try await MobileChatHost.start(jobs: jobs) { [weak self] name in
                Task { @MainActor in
                    self?.deviceChanged(name, serviceID: id)
                }
            }
            configuration.enabled = true
            save()
            let name = await host.pairedDeviceName()
            service = .running(Connection(id: id, host: host, enrollment: name.map(Enrollment.paired) ?? .unpaired))
        } catch {
            service = .stopped
            issue = .start
        }
    }

    func disable() async {
        let connection: Connection?
        switch service {
        case .running(let current): connection = current
        case .stopped where configuration.enabled: connection = nil
        default: return
        }

        service = .stopping
        do {
            if let connection {
                await connection.host.cancelInvitation()
                try await connection.host.revoke()
            } else {
                try await Task.detached(priority: .userInitiated) {
                    try MobileChatHost.revokePersistedDevice()
                }.value
            }
            configuration.enabled = false
            save()
            await connection?.host.close()
            service = .stopped
            issue = nil
        } catch {
            if var restored = connection {
                let name = await restored.host.pairedDeviceName()
                restored.enrollment = name.map(Enrollment.paired) ?? .unpaired
                service = .running(restored)
            } else {
                service = .stopped
            }
            issue = .revoke
        }
    }

    func generateInvitation() async {
        guard case .running(var connection) = service, case .unpaired = connection.enrollment else { return }
        connection.enrollment = .openingInvitation
        service = .running(connection)
        issue = nil
        do {
            let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let macName = hostName.isEmpty
                ? String(localized: "mobileChat.macName", defaultValue: "Mac")
                : String(decoding: hostName.utf8.prefix(240), as: UTF8.self)
            let code = try await connection.host.newInvitation(macName: macName)
            guard case .running(var current) = service, current.id == connection.id,
                  case .openingInvitation = current.enrollment else { return }
            guard let url = code.url, let qrImage = Self.makeImage(from: url) else {
                await connection.host.cancelInvitation()
                throw IssueError.invalidCode
            }
            let invitation = Invitation(url: url, expiresAt: .now.addingTimeInterval(300), image: qrImage)
            current.enrollment = .invitation(invitation)
            service = .running(current)
            let invitationID = invitation.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                self?.expireInvitation(invitationID)
            }
        } catch {
            guard case .running(var current) = service, current.id == connection.id,
                  case .openingInvitation = current.enrollment else { return }
            current.enrollment = .unpaired
            service = .running(current)
            issue = .invitation
        }
    }

    func cancelInvitation() async {
        guard case .running(var connection) = service, case .invitation = connection.enrollment else { return }
        connection.enrollment = .cancellingInvitation
        service = .running(connection)
        await connection.host.cancelInvitation()
        guard case .running(var current) = service, current.id == connection.id,
              case .cancellingInvitation = current.enrollment else { return }
        current.enrollment = .unpaired
        service = .running(current)
    }

    func revoke() async {
        guard case .running(var connection) = service, case .paired(let name) = connection.enrollment else { return }
        connection.enrollment = .revoking(name)
        service = .running(connection)
        issue = nil
        do {
            try await connection.host.revoke()
            deviceChanged(nil, serviceID: connection.id)
        } catch {
            guard case .running(var current) = service, current.id == connection.id else { return }
            current.enrollment = .paired(name)
            service = .running(current)
            issue = .revoke
        }
    }

    func copyPairingCode() {
        guard case .running(let connection) = service,
              case .invitation(let invitation) = connection.enrollment,
              invitation.expiresAt > .now else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation.url.absoluteString, forType: .string)
    }

    private enum IssueError: Error { case invalidCode, missingSupportDirectory }

    private static func resolveRepository(_ directory: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            GitWorktreeManager.resolveRepoRoot(from: directory.path)
                .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL }
        }.value
    }

    private static func openJobs(repository: Repository, program: URL) async throws -> MobileChatJobs {
        try await Task.detached(priority: .userInitiated) {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                  let bundleID = Bundle.main.bundleIdentifier else {
                throw IssueError.missingSupportDirectory
            }
            let directory = support.appendingPathComponent("programa/companion", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(repository.id.uuidString, isDirectory: true)
            let configuration = MobileChatRepositoryConfiguration(
                id: repository.id,
                name: repository.checkout.lastPathComponent,
                checkout: repository.checkout
            )
            return try MobileChatJobs(directory: directory, repositories: [configuration], claudeExecutable: program)
        }.value
    }

    private func chooseFile(directory: Bool) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ? checkout : executable.deletingLastPathComponent()
        panel.prompt = String(localized: "mobileChat.choose", defaultValue: "Choose")
        if let window = NSApp.keyWindow {
            let response = await panel.beginSheetModal(for: window)
            return response == .OK ? panel.url : nil
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func makeImage(from url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let qr = filter.outputImage else { return nil }
        let scaled = qr.transformed(by: .init(scaleX: 4, y: 4))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func deviceChanged(_ name: String?, serviceID: UUID) {
        guard case .running(var current) = service, current.id == serviceID else { return }
        current.enrollment = name.map(Enrollment.paired) ?? .unpaired
        service = .running(current)
    }

    private func expireInvitation(_ invitationID: UUID) {
        guard case .running(var current) = service, case .invitation(let invitation) = current.enrollment,
              invitation.id == invitationID else { return }
        current.enrollment = .unpaired
        service = .running(current)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct MobileChatCompanionView: View {
    private enum Confirmation: Identifiable {
        case revoke
        case disable

        var id: Self { self }
    }

    private let model = MobileChatCompanionModel.shared
    @State private var confirmation: Confirmation?

    var body: some View {
        Form {
            Section(String(localized: "mobileChat.section.project", defaultValue: "Project")) {
                HStack {
                    Text(String(localized: "mobileChat.repository", defaultValue: "Repository"))
                    Spacer(minLength: 12)
                    pathLabel(model.checkout)
                    Button(String(localized: "mobileChat.choose", defaultValue: "Choose")) {
                        Task { await model.chooseRepository() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text(String(localized: "mobileChat.chooseRepository", defaultValue: "Choose Repository")))
                    .disabled(!model.canChooseRepository)
                }
                .accessibilityElement(children: .contain)
                HStack {
                    Text(String(localized: "mobileChat.executable", defaultValue: "Claude Code"))
                    Spacer(minLength: 12)
                    pathLabel(model.executable)
                    Button(String(localized: "mobileChat.choose", defaultValue: "Choose")) {
                        Task { await model.chooseExecutable() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text(String(localized: "mobileChat.chooseExecutable", defaultValue: "Choose Claude Code")))
                    .disabled(!model.canChooseExecutable)
                }
                .accessibilityElement(children: .contain)
            }
            Section {
                serviceControls
                if let issue = model.issue {
                    Label(issue.message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "mobileChat.section.connection", defaultValue: "iPhone Connection"))
            } footer: {
                Text(String(localized: "mobileChat.keepOpen", defaultValue: "Keep Programa open and this Mac awake to run jobs from your iPhone."))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 320)
        .alert(item: $confirmation) { action in
            switch action {
            case .revoke:
                Alert(
                    title: Text(String(localized: "mobileChat.revoke.confirm", defaultValue: "Remove access for this iPhone?")),
                    primaryButton: .destructive(Text(String(localized: "mobileChat.revoke", defaultValue: "Remove Access"))) {
                        Task { await model.revoke() }
                    },
                    secondaryButton: .cancel()
                )
            case .disable:
                Alert(
                    title: Text(String(localized: "mobileChat.disable.confirm", defaultValue: "Turn off iPhone access on this Mac?")),
                    message: Text(String(localized: "mobileChat.disable.message", defaultValue: "A paired iPhone will need to pair again. Existing worktrees stay on this Mac.")),
                    primaryButton: .destructive(Text(String(localized: "mobileChat.disable", defaultValue: "Turn Off"))) {
                        Task { await model.disable() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    @ViewBuilder
    private var serviceControls: some View {
        switch model.service {
        case .stopped:
            Button(String(localized: "mobileChat.enable", defaultValue: "Turn On iPhone Access")) {
                Task { await model.enable() }
            }
            .disabled(model.checkout == nil)
            if model.isOptedIn { disableButton }
        case .starting:
            ProgressView(String(localized: "mobileChat.starting", defaultValue: "Starting the iPhone connection…"))
        case .stopping:
            ProgressView(String(localized: "mobileChat.stopping", defaultValue: "Turning off iPhone access…"))
        case .running(let connection):
            enrollmentControls(connection.enrollment)
            if case .unpaired = connection.enrollment {
                disableButton
            } else if case .paired = connection.enrollment {
                disableButton
            }
        }
    }

    private var disableButton: some View {
        Button(String(localized: "mobileChat.disable", defaultValue: "Turn Off"), role: .destructive) {
            confirmation = .disable
        }
    }

    @ViewBuilder
    private func enrollmentControls(_ enrollment: MobileChatCompanionModel.Enrollment) -> some View {
        switch enrollment {
        case .unpaired:
            Button(String(localized: "mobileChat.pair", defaultValue: "Pair an iPhone…")) {
                Task { await model.generateInvitation() }
            }
        case .openingInvitation:
            ProgressView(String(localized: "mobileChat.preparingCode", defaultValue: "Preparing a pairing code…"))
        case .invitation(let invitation):
            invitationView(invitation)
        case .cancellingInvitation:
            ProgressView(String(localized: "mobileChat.cancellingCode", defaultValue: "Cancelling pairing…"))
        case .paired(let name):
            LabeledContent(String(localized: "mobileChat.pairedDevice", defaultValue: "Paired iPhone")) {
                Text(verbatim: name)
            }
            Button(String(localized: "mobileChat.revoke", defaultValue: "Remove Access"), role: .destructive) {
                confirmation = .revoke
            }
        case .revoking(let name):
            LabeledContent(String(localized: "mobileChat.pairedDevice", defaultValue: "Paired iPhone")) {
                Text(verbatim: name)
            }
            ProgressView(String(localized: "mobileChat.revoking", defaultValue: "Removing access…"))
        }
    }

    private func invitationView(_ invitation: MobileChatCompanionModel.Invitation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "mobileChat.scan", defaultValue: "Scan this code in Programa on your iPhone."))
            Image(nsImage: invitation.image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: 184, height: 184)
                .padding(12)
                .background(.white)
                .accessibilityHidden(true)
            LabeledContent(String(localized: "mobileChat.expires", defaultValue: "Code expires in")) {
                Text(timerInterval: min(.now, invitation.expiresAt)...invitation.expiresAt, countsDown: true)
                    .monospacedDigit()
            }
            HStack {
                Button(String(localized: "mobileChat.copyCode", defaultValue: "Copy Pairing Code")) {
                    model.copyPairingCode()
                }
                Button(String(localized: "mobileChat.cancelPairing", defaultValue: "Cancel Pairing")) {
                    Task { await model.cancelInvitation() }
                }
            }
        }
    }

    @ViewBuilder
    private func pathLabel(_ url: URL?) -> some View {
        if let url {
            Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
        } else {
            Text(String(localized: "mobileChat.noRepository", defaultValue: "No repository selected"))
                .foregroundStyle(.secondary)
        }
    }
}
