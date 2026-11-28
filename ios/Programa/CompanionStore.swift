import Foundation
import Observation

@MainActor @Observable final class CompanionStore {
    enum Connection {
        case loading
        case unpaired(CompanionIssue?)
        case pairing
        case online(PairedMac)
        case offline(PairedMac, CompanionIssue)

        var mac: PairedMac? {
            switch self {
            case let .online(mac), let .offline(mac, _): mac
            case .loading, .unpaired, .pairing: nil
            }
        }
    }

    private(set) var connection: Connection = .loading
    private(set) var repositories: [MobileChatRepository] = []
    private(set) var jobs: [MobileChatJob] = []
    private let client = CompanionClient()
    private var pairingGeneration = UUID()
    private var jobsGeneration = 0

    func launch() async {
        guard case .loading = connection else { return }
        do {
            if let mac = try await client.savedMac() {
                connection = .online(mac)
            } else {
                connection = .unpaired(nil)
            }
        } catch {
            connection = .unpaired(CompanionIssue(error))
        }
    }

    func pair(_ code: String, deviceName: String) async -> Bool {
        guard case .unpaired = connection else { return false }
        connection = .pairing
        do {
            let mac = try await client.pair(with: code, deviceName: deviceName)
            pairingGeneration = UUID()
            connection = .online(mac)
            await refresh()
            return true
        } catch {
            connection = .unpaired(CompanionIssue(error))
            return false
        }
    }

    func forgetMac() async {
        guard let mac = connection.mac else { return }
        pairingGeneration = UUID()
        do {
            try await client.forget()
            repositories = []
            jobs = []
            connection = .unpaired(nil)
        } catch {
            connection = .offline(mac, CompanionIssue(error))
        }
    }

    func suspend() async {
        await client.disconnect()
    }

    func refreshInbox() async {
        await launch()
        await refresh()
        while !Task.isCancelled, jobs.contains(where: { $0.state.isActive }) {
            let delay: Duration = if case .offline = connection { .seconds(8) } else { .seconds(2) }
            do { try await Task.sleep(for: delay) } catch { return }
            await refresh()
        }
    }

    func refresh() async {
        let revision = jobsGeneration
        do {
            let response = try await request(.list)
            guard case let .snapshot(snapshot) = response else { throw CompanionIssue.unexpectedReply }
            repositories = snapshot.repositories
            if revision == jobsGeneration {
                jobs = snapshot.jobs.sorted { $0.updatedAt > $1.updatedAt }
            }
        } catch {
            if case CompanionIssue.unexpectedReply = error, let mac = connection.mac {
                connection = .offline(mac, .unexpectedReply)
            }
        }
    }

    func submit(_ request: MobileChatRequest) async throws -> MobileChatJob {
        guard case let .job(job) = try await self.request(request) else { throw CompanionIssue.unexpectedReply }
        merge(job)
        return job
    }

    func history(for jobID: UUID, before: UUID? = nil) async throws -> MobileChatConversation {
        guard case let .conversation(page) = try await request(.history(jobID: jobID, before: before)),
              page.job.id == jobID else { throw CompanionIssue.unexpectedReply }
        merge(page.job)
        return page
    }

    func job(_ id: UUID) -> MobileChatJob? {
        jobs.first { $0.id == id }
    }

    private func request(_ request: MobileChatRequest) async throws -> MobileChatResponse {
        guard let mac = connection.mac else { throw CompanionIssue.refused(.unauthorized) }
        let generation = pairingGeneration
        do {
            let response = try await client.request(request, on: mac)
            try Task.checkCancellation()
            guard pairingGeneration == generation else { throw CancellationError() }
            connection = .online(mac)
            return response
        } catch {
            if Task.isCancelled || pairingGeneration != generation { throw CancellationError() }
            let issue = CompanionIssue(error)
            switch issue {
            case .refused(.unauthorized), .unreachable, .unexpectedReply:
                connection = .offline(mac, issue)
            case .refused, .malformedCode, .pairingRefused, .credential:
                break
            }
            throw issue
        }
    }

    private func merge(_ job: MobileChatJob) {
        if let existing = jobs.firstIndex(where: { $0.id == job.id }) {
            guard jobs[existing].updatedAt <= job.updatedAt else { return }
            jobs[existing] = job
        } else {
            jobs.append(job)
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
        jobsGeneration += 1
    }
}

extension MobileChatJobState {
    var isActive: Bool {
        switch self {
        case .queued, .running: true
        case .ready, .interrupted, .failed: false
        }
    }

    var label: String {
        switch self {
        case .queued: String(localized: "job.queued", defaultValue: "Queued")
        case .running: String(localized: "job.running", defaultValue: "Working")
        case .ready: String(localized: "job.ready", defaultValue: "Ready")
        case .interrupted: String(localized: "job.interrupted", defaultValue: "Interrupted")
        case .failed: String(localized: "job.failed", defaultValue: "Failed")
        }
    }
}
