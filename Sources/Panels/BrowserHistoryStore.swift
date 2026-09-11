import Foundation
import Combine
import os

func normalizedBrowserHistoryNamespace(bundleIdentifier: String) -> String {
    if bundleIdentifier.hasPrefix("com.darkroom.programa.debug.") {
        return "com.darkroom.programa.debug"
    }
    if bundleIdentifier.hasPrefix("com.darkroom.programa.staging.") {
        return "com.darkroom.programa.staging"
    }
    return bundleIdentifier
}

@MainActor
final class BrowserHistoryStore: ObservableObject {
    static let shared = BrowserHistoryStore()
    /// History is capped at 5,000 entries; 16 MiB leaves ample room for titles and URLs
    /// while preventing a corrupt or replaced file from being read without a bound.
    nonisolated static let maxPersistenceBytes = 16 * 1024 * 1024
    nonisolated private static let maxEntryTextBytes = 64 * 1024

    enum PersistenceLoadError: Error, Equatable {
        case exceedsByteLimit
    }

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        var url: String
        var title: String?
        var lastVisited: Date
        var visitCount: Int
        var typedCount: Int
        var lastTypedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case url
            case title
            case lastVisited
            case visitCount
            case typedCount
            case lastTypedAt
        }

        init(
            id: UUID,
            url: String,
            title: String?,
            lastVisited: Date,
            visitCount: Int,
            typedCount: Int = 0,
            lastTypedAt: Date? = nil
        ) {
            self.id = id
            self.url = url
            self.title = title
            self.lastVisited = lastVisited
            self.visitCount = visitCount
            self.typedCount = typedCount
            self.lastTypedAt = lastTypedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            url = try container.decode(String.self, forKey: .url)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            lastVisited = try container.decode(Date.self, forKey: .lastVisited)
            visitCount = try container.decode(Int.self, forKey: .visitCount)
            typedCount = try container.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
            lastTypedAt = try container.decodeIfPresent(Date.self, forKey: .lastTypedAt)
        }
    }

    struct Persistence: Sendable {
        let load: @Sendable (URL) throws -> Data
        let persist: @Sendable ([Entry], URL) throws -> Void
        let remove: @Sendable (URL) throws -> Void

        nonisolated static let live = Persistence(
            load: { fileURL in
                try BrowserHistoryStore.readPersistedData(from: fileURL)
            },
            persist: { snapshot, fileURL in
                try BrowserHistoryStore.persistSnapshot(snapshot, to: fileURL)
            },
            remove: { fileURL in
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: fileURL.path) else { return }
                try fileManager.removeItem(at: fileURL)
            }
        )
    }

    private final class SaveCancellationToken: Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        func cancel() {
            cancelled.withLock { $0 = true }
        }

        var isCancelled: Bool {
            cancelled.withLock { $0 }
        }
    }

    private struct PendingSave {
        let workItem: DispatchWorkItem
        let cancellationToken: SaveCancellationToken
    }

    private enum LoadState {
        case notLoaded
        case loaded
        case failed
    }

    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL?
    private let persistence: Persistence
    private let persistenceQueue = DispatchQueue(
        label: "com.darkroom.programa.browser-history.persistence",
        qos: .utility
    )
    private var loadState: LoadState = .notLoaded
    private var pendingSave: PendingSave?
    private var mutationRevision: UInt64 = 0
    private var isDirty: Bool = false
    private let maxEntries: Int = 5000
    private let saveDebounceNanoseconds: UInt64 = 120_000_000

    private struct SuggestionCandidate {
        let entry: Entry
        let urlLower: String
        let urlSansSchemeLower: String
        let hostLower: String
        let pathAndQueryLower: String
        let titleLower: String
    }

    private struct ScoredSuggestion {
        let entry: Entry
        let score: Double
    }

    init(fileURL: URL? = nil, persistence: Persistence = .live) {
        // Avoid calling @MainActor-isolated static methods from default argument context.
        self.fileURL = fileURL ?? BrowserHistoryStore.defaultHistoryFileURL()
        self.persistence = persistence
    }

    @discardableResult
    func loadIfNeeded(retryAfterFailure: Bool = true) -> Bool {
        if case .loaded = loadState { return true }
        if case .failed = loadState, !retryAfterFailure { return false }
        guard let fileURL else {
            loadState = .loaded
            return true
        }
        migrateLegacyTaggedHistoryFileIfNeeded(to: fileURL)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadState = .loaded
            return true
        }

        // Load synchronously on first access so the first omnibar query can use
        // persisted history immediately (important for deterministic UI behavior).
        let data: Data
        do {
            data = try Self.boundedPersistenceData(persistence.load(fileURL))
        } catch {
            loadState = .failed
            return false
        }

        let decoded: [Entry]
        do {
            decoded = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            loadState = .failed
            return false
        }

        // Most-recent first.
        let normalized = decoded.compactMap(Self.normalizedPersistenceEntry)
        entries = Array(normalized.sorted(by: { $0.lastVisited > $1.lastVisited }).prefix(maxEntries))
        loadState = .loaded

        // Remove entries with invalid hosts (no TLD), e.g. "https://news."
        let beforeCount = entries.count
        entries.removeAll { entry in
            guard let url = URL(string: entry.url),
                  let host = url.host?.lowercased() else { return false }
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            return !trimmed.contains(".")
        }
        if entries.count != beforeCount || normalized != decoded {
            scheduleSave()
        }
        return true
    }

    func recordVisit(url: URL?, title: String?) {
        guard loadIfNeeded() else { return }

        guard let url, url.absoluteString.utf8.count <= Self.maxEntryTextBytes else { return }
        let title = title.map { SidebarTelemetryLimits.truncatedToUTF8Limit($0, maxBytes: Self.maxEntryTextBytes) }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Skip URLs whose host lacks a TLD (e.g. "https://news.").
        if let host = url.host?.lowercased() {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmed.contains(".") { return }
        }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }
        let normalizedKey = normalizedHistoryKey(url: url)

        if let idx = entries.firstIndex(where: {
            if $0.url == urlString { return true }
            return normalizedHistoryKey(urlString: $0.url) == normalizedKey
        }) {
            entries[idx].lastVisited = Date()
            entries[idx].visitCount += 1
            // Prefer non-empty titles, but don't clobber an existing title with empty/whitespace.
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[idx].title = title
            }
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                lastVisited: Date(),
                visitCount: 1
            ), at: 0)
        }

        // Keep most-recent first and bound size.
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    func recordTypedNavigation(url: URL?) {
        guard loadIfNeeded() else { return }

        guard let url, url.absoluteString.utf8.count <= Self.maxEntryTextBytes else { return }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // Skip URLs whose host lacks a TLD (e.g. "https://news.").
        if let host = url.host?.lowercased() {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmed.contains(".") { return }
        }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }

        let now = Date()
        let normalizedKey = normalizedHistoryKey(url: url)
        if let idx = entries.firstIndex(where: {
            if $0.url == urlString { return true }
            return normalizedHistoryKey(urlString: $0.url) == normalizedKey
        }) {
            entries[idx].typedCount += 1
            entries[idx].lastTypedAt = now
            entries[idx].lastVisited = now
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: nil,
                lastVisited: now,
                visitCount: 1,
                typedCount: 1,
                lastTypedAt: now
            ), at: 0)
        }

        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    func suggestions(for input: String, limit: Int = 10) -> [Entry] {
        _ = loadIfNeeded(retryAfterFailure: false)
        guard limit > 0 else { return [] }

        let q = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let queryTokens = tokenizeSuggestionQuery(q)
        let now = Date()

        let matched = entries.compactMap { entry -> ScoredSuggestion? in
            let candidate = makeSuggestionCandidate(entry: entry)
            guard let score = suggestionScore(candidate: candidate, query: q, queryTokens: queryTokens, now: now) else {
                return nil
            }
            return ScoredSuggestion(entry: entry, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lastVisited != rhs.entry.lastVisited { return lhs.entry.lastVisited > rhs.entry.lastVisited }
            if lhs.entry.visitCount != rhs.entry.visitCount { return lhs.entry.visitCount > rhs.entry.visitCount }
            return lhs.entry.url < rhs.entry.url
        }

        if matched.count <= limit { return matched.map(\.entry) }
        return Array(matched.prefix(limit).map(\.entry))
    }

    func recentSuggestions(limit: Int = 10) -> [Entry] {
        _ = loadIfNeeded(retryAfterFailure: false)
        guard limit > 0 else { return [] }

        let ranked = entries.sorted { lhs, rhs in
            if lhs.typedCount != rhs.typedCount { return lhs.typedCount > rhs.typedCount }
            let lhsTypedDate = lhs.lastTypedAt ?? .distantPast
            let rhsTypedDate = rhs.lastTypedAt ?? .distantPast
            if lhsTypedDate != rhsTypedDate { return lhsTypedDate > rhsTypedDate }
            if lhs.lastVisited != rhs.lastVisited { return lhs.lastVisited > rhs.lastVisited }
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return lhs.url < rhs.url
        }

        if ranked.count <= limit { return ranked }
        return Array(ranked.prefix(limit))
    }

    @discardableResult
    func mergeImportedEntries(_ importedEntries: [Entry]) -> Int {
        guard loadIfNeeded() else { return 0 }
        guard !importedEntries.isEmpty else { return 0 }

        var mergedCount = 0
        for imported in importedEntries {
            guard let imported = Self.normalizedPersistenceEntry(imported),
                  let parsedURL = URL(string: imported.url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }

            if let host = parsedURL.host?.lowercased() {
                let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
                if !trimmed.contains(".") { continue }
            }

            let urlString = parsedURL.absoluteString
            guard urlString != "about:blank", urlString.utf8.count <= Self.maxEntryTextBytes else { continue }
            let normalizedKey = normalizedHistoryKey(url: parsedURL)

            let importedTitle = imported.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let importedLastVisited = imported.lastVisited
            let importedVisitCount = max(1, imported.visitCount)
            let importedTypedCount = max(0, imported.typedCount)
            let importedLastTypedAt = imported.lastTypedAt

            if let idx = entries.firstIndex(where: {
                if $0.url == urlString { return true }
                guard let normalizedKey else { return false }
                return normalizedHistoryKey(urlString: $0.url) == normalizedKey
            }) {
                var didMutate = false
                if importedLastVisited > entries[idx].lastVisited {
                    entries[idx].lastVisited = importedLastVisited
                    didMutate = true
                }
                if importedVisitCount > entries[idx].visitCount {
                    entries[idx].visitCount = importedVisitCount
                    didMutate = true
                }
                if importedTypedCount > entries[idx].typedCount {
                    entries[idx].typedCount = importedTypedCount
                    didMutate = true
                }
                if let importedLastTypedAt {
                    if let existingLastTypedAt = entries[idx].lastTypedAt {
                        if importedLastTypedAt > existingLastTypedAt {
                            entries[idx].lastTypedAt = importedLastTypedAt
                            didMutate = true
                        }
                    } else {
                        entries[idx].lastTypedAt = importedLastTypedAt
                        didMutate = true
                    }
                }

                let existingTitle = entries[idx].title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let incomingTitle = importedTitle ?? ""
                if !incomingTitle.isEmpty,
                   (existingTitle.isEmpty || importedLastVisited >= entries[idx].lastVisited) {
                    if entries[idx].title != incomingTitle {
                        entries[idx].title = incomingTitle
                        didMutate = true
                    }
                }

                if didMutate {
                    mergedCount += 1
                }
            } else {
                entries.append(Entry(
                    id: UUID(),
                    url: urlString,
                    title: importedTitle,
                    lastVisited: importedLastVisited,
                    visitCount: importedVisitCount,
                    typedCount: importedTypedCount,
                    lastTypedAt: importedLastTypedAt
                ))
                mergedCount += 1
            }
        }

        guard mergedCount > 0 else { return 0 }
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        scheduleSave()
        return mergedCount
    }

    func clearHistory() {
        _ = loadIfNeeded()
        cancelPendingSave()
        entries = []
        guard let fileURL else { return }

        mutationRevision += 1
        let revision = mutationRevision
        isDirty = true
        let succeeded = persistenceQueue.sync {
            do {
                try persistence.remove(fileURL)
                return true
            } catch {
                return false
            }
        }
        loadState = .loaded
        completePersistence(revision: revision, succeeded: succeeded)
    }

    @discardableResult
    func removeHistoryEntry(urlString: String) -> Bool {
        guard loadIfNeeded() else { return false }
        let normalized = normalizedHistoryKey(urlString: urlString)
        let originalCount = entries.count
        entries.removeAll { entry in
            if entry.url == urlString { return true }
            guard let normalized else { return false }
            return normalizedHistoryKey(urlString: entry.url) == normalized
        }
        let didRemove = entries.count != originalCount
        if didRemove {
            scheduleSave()
        }
        return didRemove
    }

    func flushPendingSaves() {
        guard loadIfNeeded() else { return }
        cancelPendingSave()
        guard let fileURL, isDirty else { return }

        let snapshot = entries
        let revision = mutationRevision
        let succeeded = persistenceQueue.sync {
            do {
                try persistence.persist(snapshot, fileURL)
                return true
            } catch {
                return false
            }
        }
        completePersistence(revision: revision, succeeded: succeeded)
    }

    private func scheduleSave() {
        guard let fileURL else { return }

        cancelPendingSave()
        mutationRevision += 1
        let revision = mutationRevision
        isDirty = true
        let snapshot = entries
        let persistence = persistence
        let cancellationToken = SaveCancellationToken()
        let workItem = DispatchWorkItem { [weak self] in
            guard !cancellationToken.isCancelled else { return }

            let succeeded: Bool
            do {
                try persistence.persist(snapshot, fileURL)
                succeeded = true
            } catch {
                succeeded = false
            }

            Task { @MainActor [weak self] in
                self?.completePersistence(revision: revision, succeeded: succeeded)
            }
        }
        pendingSave = PendingSave(workItem: workItem, cancellationToken: cancellationToken)
        persistenceQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(saveDebounceNanoseconds)),
            execute: workItem
        )
    }

    private func cancelPendingSave() {
        pendingSave?.cancellationToken.cancel()
        pendingSave?.workItem.cancel()
        pendingSave = nil
    }

    private func completePersistence(revision: UInt64, succeeded: Bool) {
        guard revision == mutationRevision else { return }
        pendingSave = nil
        if succeeded {
            isDirty = false
        }
    }

    private func migrateLegacyTaggedHistoryFileIfNeeded(to targetURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: targetURL.path) else { return }
        guard let legacyURL = Self.legacyTaggedHistoryFileURL(),
              legacyURL != targetURL,
              fm.fileExists(atPath: legacyURL.path) else {
            return
        }

        do {
            let dir = targetURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            try fm.copyItem(at: legacyURL, to: targetURL)
        } catch {
            return
        }
    }

    private func makeSuggestionCandidate(entry: Entry) -> SuggestionCandidate {
        let urlLower = entry.url.lowercased()
        let urlSansSchemeLower = stripHTTPSSchemePrefix(urlLower)
        let components = URLComponents(string: entry.url)
        let hostLower = components?.host?.lowercased() ?? ""
        let path = (components?.percentEncodedPath ?? components?.path ?? "").lowercased()
        let query = (components?.percentEncodedQuery ?? components?.query ?? "").lowercased()
        let pathAndQueryLower: String
        if query.isEmpty {
            pathAndQueryLower = path
        } else {
            pathAndQueryLower = "\(path)?\(query)"
        }
        let titleLower = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SuggestionCandidate(
            entry: entry,
            urlLower: urlLower,
            urlSansSchemeLower: urlSansSchemeLower,
            hostLower: hostLower,
            pathAndQueryLower: pathAndQueryLower,
            titleLower: titleLower
        )
    }

    private func suggestionScore(
        candidate: SuggestionCandidate,
        query: String,
        queryTokens: [String],
        now: Date
    ) -> Double? {
        let queryIncludesScheme = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlMatchValue = queryIncludesScheme ? candidate.urlLower : candidate.urlSansSchemeLower
        let isSingleCharacterQuery = query.count == 1
        if isSingleCharacterQuery {
            let hasSingleCharStrongMatch =
                candidate.hostLower.hasPrefix(query) ||
                candidate.titleLower.hasPrefix(query) ||
                urlMatchValue.hasPrefix(query)
            guard hasSingleCharStrongMatch else { return nil }
        }

        let queryMatches =
            urlMatchValue.contains(query) ||
            candidate.hostLower.contains(query) ||
            candidate.pathAndQueryLower.contains(query) ||
            candidate.titleLower.contains(query)

        let tokenMatches = !queryTokens.isEmpty && queryTokens.allSatisfy { token in
            candidate.urlSansSchemeLower.contains(token) ||
            candidate.hostLower.contains(token) ||
            candidate.pathAndQueryLower.contains(token) ||
            candidate.titleLower.contains(token)
        }

        guard queryMatches || tokenMatches else { return nil }

        var score = 0.0

        if urlMatchValue == query { score += 1200 }
        if candidate.hostLower == query { score += 980 }
        if candidate.hostLower.hasPrefix(query) { score += 680 }
        if urlMatchValue.hasPrefix(query) { score += 560 }
        if candidate.titleLower.hasPrefix(query) { score += 420 }
        if candidate.pathAndQueryLower.hasPrefix(query) { score += 300 }

        if candidate.hostLower.contains(query) { score += 210 }
        if candidate.pathAndQueryLower.contains(query) { score += 165 }
        if candidate.titleLower.contains(query) { score += 145 }

        for token in queryTokens {
            if candidate.hostLower == token { score += 260 }
            else if candidate.hostLower.hasPrefix(token) { score += 170 }
            else if candidate.hostLower.contains(token) { score += 110 }

            if candidate.pathAndQueryLower.hasPrefix(token) { score += 80 }
            else if candidate.pathAndQueryLower.contains(token) { score += 52 }

            if candidate.titleLower.hasPrefix(token) { score += 74 }
            else if candidate.titleLower.contains(token) { score += 48 }
        }

        // Blend recency and repeat visits so history feels closer to browser frecency.
        let ageHours = max(0, now.timeIntervalSince(candidate.entry.lastVisited) / 3600)
        let recencyScore = max(0, 110 - (ageHours / 3))
        let frequencyScore = min(120, log1p(Double(max(1, candidate.entry.visitCount))) * 38)
        let typedFrequencyScore = min(190, log1p(Double(max(0, candidate.entry.typedCount))) * 80)
        let typedRecencyScore: Double
        if let lastTypedAt = candidate.entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            typedRecencyScore = max(0, 85 - (typedAgeHours / 4))
        } else {
            typedRecencyScore = 0
        }
        score += recencyScore + frequencyScore + typedFrequencyScore + typedRecencyScore

        return score
    }

    private func stripHTTPSSchemePrefix(_ value: String) -> String {
        if value.hasPrefix("https://") {
            return String(value.dropFirst("https://".count))
        }
        if value.hasPrefix("http://") {
            return String(value.dropFirst("http://".count))
        }
        return value
    }

    private func normalizedHistoryKey(url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        return normalizedHistoryKey(components: &components)
    }

    private func normalizedHistoryKey(urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else { return nil }
        return normalizedHistoryKey(components: &components)
    }

    private func canonicalizedPercentEscapes(in value: String) -> String {
        func isHexDigit(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x30...0x39, 0x41...0x46, 0x61...0x66: true
            default: false
            }
        }

        var bytes = Array(value.utf8)
        var index = 0
        while index + 2 < bytes.count {
            guard bytes[index] == 0x25,
                  isHexDigit(bytes[index + 1]),
                  isHexDigit(bytes[index + 2]) else {
                index += 1
                continue
            }

            if bytes[index + 1] >= 0x61 { bytes[index + 1] -= 0x20 }
            if bytes[index + 2] >= 0x61 { bytes[index + 2] -= 0x20 }
            index += 3
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func normalizedHistoryKey(components: inout URLComponents) -> String? {
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased() else {
            return nil
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }

        let portPart: String
        if let port = components.port {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let queryPart: String
        if let query = components.percentEncodedQuery, !query.isEmpty {
            queryPart = "?\(canonicalizedPercentEscapes(in: query))"
        } else {
            queryPart = ""
        }

        return "\(scheme)://\(host)\(portPart)\(path)\(queryPart)"
    }

    private func tokenizeSuggestionQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        for raw in query.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    nonisolated private static func defaultHistoryFileURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.darkroom.programa"
        let namespace = normalizedBrowserHistoryNamespace(bundleIdentifier: bundleId)
        let dir = appSupport.appendingPathComponent(namespace, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    nonisolated private static func legacyTaggedHistoryFileURL() -> URL? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let namespace = normalizedBrowserHistoryNamespace(bundleIdentifier: bundleId)
        guard namespace != bundleId else { return nil }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    nonisolated private static func normalizedPersistenceEntry(_ entry: Entry) -> Entry? {
        guard entry.url.utf8.count <= maxEntryTextBytes else { return nil }
        var entry = entry
        entry.title = entry.title.map {
            SidebarTelemetryLimits.truncatedToUTF8Limit($0, maxBytes: maxEntryTextBytes)
        }
        return entry
    }

    nonisolated private static func persistSnapshot(_ snapshot: [Entry], to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = Data([0x5B])
        for entry in snapshot {
            guard let entry = normalizedPersistenceEntry(entry) else { continue }
            let encoded = try encoder.encode(entry)
            let separatorBytes = data.count > 1 ? 1 : 0
            // Count encoded bytes, including escaping, the comma, and closing bracket.
            guard data.count + separatorBytes + encoded.count + 1 <= maxPersistenceBytes else { break }
            if separatorBytes != 0 { data.append(0x2C) }
            data.append(encoded)
        }
        data.append(0x5D)
        try data.write(to: fileURL, options: [.atomic])
    }

    nonisolated static func boundedPersistenceData(_ data: Data) throws -> Data {
        guard data.count <= maxPersistenceBytes else { throw PersistenceLoadError.exceedsByteLimit }
        return data
    }

    nonisolated private static func readPersistedData(from fileURL: URL) throws -> Data {
        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize, fileSize > maxPersistenceBytes {
            throw PersistenceLoadError.exceedsByteLimit
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxPersistenceBytes + 1) ?? Data()
        return try boundedPersistenceData(data)
    }

    nonisolated static func defaultHistoryFileURLForCurrentBundle() -> URL? {
        defaultHistoryFileURL()
    }

    nonisolated static func normalizedBrowserHistoryNamespaceForBundleIdentifier(_ bundleIdentifier: String) -> String {
        normalizedBrowserHistoryNamespace(bundleIdentifier: bundleIdentifier)
    }
}

actor BrowserSearchSuggestionService {
    static let shared = BrowserSearchSuggestionService()

    typealias RequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let requestLoader: RequestLoader

    init(
        requestLoader: @escaping RequestLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.requestLoader = requestLoader
    }

    func suggestions(engine: BrowserSearchEngine, query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Deterministic UI-test hook for validating remote suggestion rendering
        // without relying on external network behavior.
        let forced = ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_REMOTE_SUGGESTIONS_JSON"]
            ?? UserDefaults.standard.string(forKey: "PROGRAMA_UI_TEST_REMOTE_SUGGESTIONS_JSON")
        if let forced,
           let data = forced.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return parsed.compactMap { item in
                guard let s = item as? String else { return nil }
                let value = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        return await fetchRemoteSuggestions(engine: engine, query: trimmed)
    }

    private func fetchRemoteSuggestions(engine: BrowserSearchEngine, query: String) async -> [String] {
        let url: URL?
        switch engine {
        case .google:
            var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            c?.queryItems = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "q", value: query),
            ]
            url = c?.url
        case .duckduckgo:
            var c = URLComponents(string: "https://duckduckgo.com/ac/")
            c?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "list"),
            ]
            url = c?.url
        case .bing:
            var c = URLComponents(string: "https://www.bing.com/osjson.aspx")
            c?.queryItems = [
                URLQueryItem(name: "query", value: query),
            ]
            url = c?.url
        case .kagi:
            var c = URLComponents(string: "https://kagi.com/api/autosuggest")
            c?.queryItems = [
                URLQueryItem(name: "q", value: query),
            ]
            url = c?.url
        case .startpage:
            var c = URLComponents(string: "https://www.startpage.com/osuggestions")
            c?.queryItems = [
                URLQueryItem(name: "q", value: query),
            ]
            url = c?.url
        }

        guard let url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 0.65
        req.cachePolicy = .returnCacheDataElseLoad
        req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader(req)
        } catch {
            return []
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }

        switch engine {
        case .google, .bing, .kagi, .startpage:
            return parseOSJSON(data: data)
        case .duckduckgo:
            return parseDuckDuckGo(data: data)
        }
    }

    private func parseOSJSON(data: Data) -> [String] {
        // Format: [query, [suggestions...], ...]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2,
              let list = root[1] as? [Any] else {
            return []
        }
        var out: [String] = []
        out.reserveCapacity(list.count)
        for item in list {
            guard let s = item as? String else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
        }
        return out
    }

    private func parseDuckDuckGo(data: Data) -> [String] {
        // Format: [{phrase:"..."}, ...]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var out: [String] = []
        out.reserveCapacity(root.count)
        for item in root {
            guard let dict = item as? [String: Any],
                  let phrase = dict["phrase"] as? String else { continue }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
        }
        return out
    }
}
