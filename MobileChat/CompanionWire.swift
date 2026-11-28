import Foundation

enum MobileChatWire {
    static let alpn = Data("programa/agent-companion/1".utf8)
    static let maximumRequestBytes = 40 * 1024
    static let maximumResponseBytes = 256 * 1024
    static let maximumPromptBytes = 16 * 1024
}

nonisolated enum MobileChatRequest: Codable, Sendable {
    case pair(code: String, deviceName: String)
    case list
    case start(jobID: UUID, messageID: UUID, repositoryID: UUID, prompt: String)
    case reply(jobID: UUID, messageID: UUID, prompt: String)
    case history(jobID: UUID, before: UUID?)
}

nonisolated enum MobileChatResponse: Codable, Sendable {
    case paired
    case snapshot(MobileChatSnapshot)
    case job(MobileChatJob)
    case conversation(MobileChatConversation)
    case failure(MobileChatFailure)
}

nonisolated enum MobileChatFailure: String, Codable, Sendable {
    case unauthorized, invalidRequest, notFound, busy, unavailable, storage
}

nonisolated struct MobileChatSnapshot: Codable, Sendable {
    let repositories: [MobileChatRepository]
    let jobs: [MobileChatJob]
}

nonisolated struct MobileChatRepository: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

nonisolated struct MobileChatJob: Codable, Identifiable, Sendable {
    let id: UUID
    let repositoryID: UUID
    let title: String
    let state: MobileChatJobState
    let updatedAt: Date
    let workspaceReference: UUID?
}

nonisolated enum MobileChatJobState: String, Codable, Sendable {
    case queued, running, ready, interrupted, failed
}

nonisolated struct MobileChatConversation: Codable, Sendable {
    let job: MobileChatJob
    let messages: [MobileChatMessage]
    let hasEarlier: Bool
}

nonisolated struct MobileChatMessage: Codable, Identifiable, Sendable {
    let id: UUID
    let role: MobileChatRole
    let text: String
    let createdAt: Date
}

nonisolated enum MobileChatRole: String, Codable, Sendable {
    case user, assistant, system
}

nonisolated struct MobileChatPairingCode: Sendable {
    let ticket: String
    let token: String
    let macName: String

    var url: URL? {
        var components = URLComponents()
        components.scheme = "programa-pair"
        components.host = "pair"
        components.queryItems = [
            .init(name: "v", value: "1"),
            .init(name: "t", value: ticket),
            .init(name: "k", value: token),
            .init(name: "n", value: macName),
        ]
        return components.url
    }

    static func parse(_ text: String) -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096,
              let components = URLComponents(string: text),
              components.scheme == "programa-pair",
              components.host == "pair",
              components.path.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems,
              items.count == 4 else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, !value.isEmpty,
                  values.updateValue(value, forKey: item.name) == nil else { return nil }
        }
        guard values["v"] == "1", let ticket = values["t"],
              let token = values["k"], token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let macName = values["n"], macName.utf8.count <= 256 else { return nil }
        return Self(ticket: ticket, token: token, macName: macName)
    }
}
