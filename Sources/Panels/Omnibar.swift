import SwiftUI
import AppKit

struct OmnibarInlineCompletion: Equatable {
    let typedText: String
    let displayText: String
    let acceptedText: String

    var suffixRange: NSRange {
        let typedCount = typedText.utf16.count
        let fullCount = displayText.utf16.count
        return NSRange(location: typedCount, length: max(0, fullCount - typedCount))
    }
}

struct OmnibarAddressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OmnibarAddressButtonStyleBody(configuration: configuration)
    }
}

struct OmnibarAddressButtonStyleBody: View {
    let configuration: OmnibarAddressButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    func programaFlatSymbolColorRendering() -> some View {
        // `symbolColorRenderingMode(.flat)` is not available in the current SDK
        // used by CI/local builds. Keep this modifier as a compatibility no-op.
        self
    }
}

enum OmnibarInputIntent: Equatable {
    case urlLike
    case queryLike
    case ambiguous
}

struct OmnibarOpenTabMatch: Equatable {
    let tabId: UUID
    let panelId: UUID
    let url: String
    let title: String?
    let isKnownOpenTab: Bool

    init(tabId: UUID, panelId: UUID, url: String, title: String?, isKnownOpenTab: Bool = true) {
        self.tabId = tabId
        self.panelId = panelId
        self.url = url
        self.title = title
        self.isKnownOpenTab = isKnownOpenTab
    }
}

func omnibarInputIntent(for query: String) -> OmnibarInputIntent {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .ambiguous }

    if resolveBrowserNavigableURL(trimmed) != nil {
        return .urlLike
    }

    if trimmed.contains(" ") {
        return .queryLike
    }

    if trimmed.contains(".") {
        return .ambiguous
    }

    return .queryLike
}

func omnibarSuggestionCompletion(for suggestion: OmnibarSuggestion) -> String? {
    switch suggestion.kind {
    case .navigate(let url):
        return url
    case .history(let url, _):
        return url
    case .switchToTab(_, _, let url, _):
        return url
    default:
        return nil
    }
}

func omnibarSuggestionTitle(for suggestion: OmnibarSuggestion) -> String? {
    switch suggestion.kind {
    case .history(_, let title):
        return title
    case .switchToTab(_, _, _, let title):
        return title
    default:
        return nil
    }
}

func omnibarSuggestionMatchesTypedPrefix(
    typedText: String,
    suggestionCompletion: String,
    suggestionTitle: String? = nil
) -> Bool {
    let trimmedQuery = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return false }

    let query = trimmedQuery.lowercased()
    let trimmedCompletion = suggestionCompletion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCompletion.isEmpty else { return false }
    let loweredCompletion = trimmedCompletion.lowercased()

    let schemeStripped = stripHTTPSchemePrefix(trimmedCompletion)
    let schemeAndWWWStripped = stripHTTPSchemeAndWWWPrefix(trimmedCompletion)
    let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
    let typedIncludesWWWPrefix = query.hasPrefix("www.")

    if typedIncludesScheme, loweredCompletion.hasPrefix(query) { return true }
    if schemeStripped.hasPrefix(query) { return true }
    if !typedIncludesWWWPrefix && schemeAndWWWStripped.hasPrefix(query) { return true }

    let normalizedTitle = suggestionTitle?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    if !normalizedTitle.isEmpty && normalizedTitle.hasPrefix(query) {
        return true
    }

    return false
}

func omnibarSuggestionSupportsAutocompletion(query: String, suggestion: OmnibarSuggestion) -> Bool {
    if case .search = suggestion.kind { return false }
    if case .remote = suggestion.kind { return false }
    guard let completion = omnibarSuggestionCompletion(for: suggestion) else { return false }
    // Reject URLs whose host lacks a TLD (e.g. "https://news." → host "news").
    if let components = URLComponents(string: completion),
       let host = components.host?.lowercased() {
        let trimmedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        if !trimmedHost.contains(".") { return false }
    }
    let title = omnibarSuggestionTitle(for: suggestion)
    return omnibarSuggestionMatchesTypedPrefix(
        typedText: query,
        suggestionCompletion: completion,
        suggestionTitle: title
    )
}

func omnibarSingleCharacterQuery(for query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.utf16.count == 1 else { return nil }
    return trimmed
}

func omnibarStrippedURL(_ value: String) -> String {
    return stripHTTPSchemeAndWWWPrefix(value)
}

func omnibarScoringCandidate(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let components = URLComponents(string: trimmed), let host = components.host?.lowercased() {
        let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalizedScheme = components.scheme?.lowercased()
        let isDefaultPort = (normalizedScheme == "http" && components.port == 80)
            || (normalizedScheme == "https" && components.port == 443)
        let portSuffix = {
            guard let port = components.port, !isDefaultPort else { return "" }
            return ":\(port)"
        }()

        var normalized = "\(hostWithoutWWW)\(portSuffix)"
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            normalized += path
        } else if path == "/" {
            normalized += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            normalized += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            normalized += "#\(fragment)"
        }
        return normalized
    }

    return stripHTTPSchemeAndWWWPrefix(trimmed)
}

func omnibarHasSingleCharacterPrefixMatch(query: String, url: String, title: String?) -> Bool {
    guard let trimmedQuery = omnibarSingleCharacterQuery(for: query) else { return false }

    let normalizedURL = omnibarStrippedURL(url).lowercased()
    let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return normalizedURL.hasPrefix(trimmedQuery) || normalizedTitle.hasPrefix(trimmedQuery)
}

func buildOmnibarSuggestions(
    query: String,
    engineName: String,
    historyEntries: [BrowserHistoryStore.Entry],
    openTabMatches: [OmnibarOpenTabMatch] = [],
    remoteQueries: [String],
    resolvedURL: URL?,
    limit: Int = 8,
    now: Date = Date()
) -> [OmnibarSuggestion] {
    guard limit > 0 else { return [] }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedQuery.isEmpty {
        return Array(historyEntries.prefix(limit).map { .history($0) })
    }
    let singleCharacterQuery = omnibarSingleCharacterQuery(for: trimmedQuery)
    let isSingleCharacterQuery = singleCharacterQuery != nil
    let shouldIncludeRemoteSuggestions = !isSingleCharacterQuery
    let filteredHistoryEntries: [BrowserHistoryStore.Entry]
    let filteredOpenTabMatches: [OmnibarOpenTabMatch]
    if let singleCharacterQuery {
        filteredHistoryEntries = historyEntries.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
        filteredOpenTabMatches = openTabMatches.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
    } else {
        filteredHistoryEntries = historyEntries
        filteredOpenTabMatches = openTabMatches
    }

    let shouldSuppressSingleCharacterSearchResult = isSingleCharacterQuery
        && (!filteredHistoryEntries.isEmpty || !filteredOpenTabMatches.isEmpty)

    struct RankedSuggestion {
        let suggestion: OmnibarSuggestion
        let score: Double
        let order: Int
        let isAutocompletableMatch: Bool
        let kindPriority: Int
    }

    var bestByCompletion: [String: RankedSuggestion] = [:]
    var order = 0
    let intent = omnibarInputIntent(for: trimmedQuery)
    let normalizedQuery = trimmedQuery.lowercased()

    func suggestionPriority(for kind: OmnibarSuggestion.Kind) -> Int {
        switch kind {
        case .search:
            return 300
        case .remote:
            return 350
        default:
            return 0
        }
    }

    func completionScore(for candidate: String) -> Double {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let q = normalizedQuery
        guard !c.isEmpty, !q.isEmpty else { return 0 }

        let scoringCandidate = omnibarScoringCandidate(c)
        if !scoringCandidate.isEmpty {
            if scoringCandidate == q { return 260 }
            if scoringCandidate.hasPrefix(q) { return 220 }
            if scoringCandidate.contains(q) { return 150 }
        }

        if c == q { return 240 }
        if c.hasPrefix(q) { return 170 }
        if c.contains(q) { return 95 }
        return 0
    }

    func insert(_ suggestion: OmnibarSuggestion, score: Double) {
        let key = suggestion.completion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        let isAutocompletableMatch = omnibarSuggestionSupportsAutocompletion(query: trimmedQuery, suggestion: suggestion)

        let ranked = RankedSuggestion(
            suggestion: suggestion,
            score: score,
            order: order,
            isAutocompletableMatch: isAutocompletableMatch,
            kindPriority: suggestionPriority(for: suggestion.kind)
        )
        order += 1
        if let existing = bestByCompletion[key] {
            let shouldReplaceExisting: Bool = {
                // For identical completions, keep "go to URL" over "switch to tab" so
                // pressing Enter performs navigation unless the user explicitly picks a tab row.
                switch (existing.suggestion.kind, ranked.suggestion.kind) {
                case (.navigate, .switchToTab):
                    return false
                case (.switchToTab, .navigate):
                    return true
                default:
                    return ranked.score > existing.score
                }
            }()
            if shouldReplaceExisting {
                bestByCompletion[key] = ranked
            }
        } else {
            bestByCompletion[key] = ranked
        }
    }

    if !(isSingleCharacterQuery && shouldSuppressSingleCharacterSearchResult) {
        let searchBaseScore: Double
        switch intent {
        case .queryLike: searchBaseScore = 820
        case .ambiguous: searchBaseScore = 540
        case .urlLike: searchBaseScore = 140
        }
        insert(.search(engineName: engineName, query: trimmedQuery), score: searchBaseScore + completionScore(for: trimmedQuery))
    }

    if let resolvedURL {
        let completion = resolvedURL.absoluteString
        let navigateBaseScore: Double
        switch intent {
        case .urlLike: navigateBaseScore = 1_020
        case .ambiguous: navigateBaseScore = 760
        case .queryLike: navigateBaseScore = 470
        }
        insert(.navigate(url: completion), score: navigateBaseScore + completionScore(for: completion))
    }

    for (index, entry) in filteredHistoryEntries.prefix(max(limit * 2, limit)).enumerated() {
        let intentBaseScore: Double
        switch intent {
        case .urlLike: intentBaseScore = 780
        case .ambiguous: intentBaseScore = 690
        case .queryLike: intentBaseScore = 600
        }
        let urlMatch = completionScore(for: entry.url)
        let titleMatch = completionScore(for: entry.title ?? "") * 0.6
        let ageHours = max(0, now.timeIntervalSince(entry.lastVisited) / 3600)
        let recencyScore = max(0, 75 - (ageHours / 5))
        let visitScore = min(95, log1p(Double(max(1, entry.visitCount))) * 32)
        let typedScore = min(230, log1p(Double(max(0, entry.typedCount))) * 100)
        let typedRecencyScore: Double
        if let lastTypedAt = entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            typedRecencyScore = max(0, 80 - (typedAgeHours / 5))
        } else {
            typedRecencyScore = 0
        }
        let positionScore = Double(max(0, 16 - index))
        let total = intentBaseScore + urlMatch + titleMatch + recencyScore + visitScore + typedScore + typedRecencyScore + positionScore
        insert(.history(entry), score: total)
    }

    for (index, match) in filteredOpenTabMatches.prefix(limit).enumerated() {
        let intentBaseScore: Double
        switch intent {
        case .urlLike: intentBaseScore = 1_180
        case .ambiguous: intentBaseScore = 980
        case .queryLike: intentBaseScore = 820
        }
        let urlMatch = completionScore(for: match.url)
        let titleMatch = completionScore(for: match.title ?? "") * 0.65
        let positionScore = Double(max(0, 14 - index)) * 0.9
        let resolvedURLBonus: Double
        if let resolvedURL,
           resolvedURL.absoluteString.caseInsensitiveCompare(match.url) == .orderedSame {
            resolvedURLBonus = 120
        } else {
            resolvedURLBonus = 0
        }
        let total = intentBaseScore + urlMatch + titleMatch + positionScore + resolvedURLBonus
        if match.isKnownOpenTab {
            insert(
                .switchToTab(tabId: match.tabId, panelId: match.panelId, url: match.url, title: match.title),
                score: total
            )
        } else {
            insert(
                OmnibarSuggestion.history(url: match.url, title: match.title),
                score: total
            )
        }
    }

    if shouldIncludeRemoteSuggestions {
        for (index, remoteQuery) in remoteQueries.prefix(limit).enumerated() {
            let trimmedRemote = remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRemote.isEmpty else { continue }

            let remoteBaseScore: Double
            switch intent {
            case .queryLike: remoteBaseScore = 690
            case .ambiguous: remoteBaseScore = 450
            case .urlLike: remoteBaseScore = 110
            }
            let positionScore = Double(max(0, 14 - index)) * 0.9
            let total = remoteBaseScore + completionScore(for: trimmedRemote) + positionScore
            insert(.remoteSearchSuggestion(trimmedRemote), score: total)
        }
    }

    let sorted = bestByCompletion.values.sorted { lhs, rhs in
        if lhs.isAutocompletableMatch != rhs.isAutocompletableMatch {
            return lhs.isAutocompletableMatch
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.kindPriority != rhs.kindPriority {
            return lhs.kindPriority < rhs.kindPriority
        }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.suggestion.completion < rhs.suggestion.completion
    }
    let suggestions = Array(sorted.map(\.suggestion).prefix(limit))
    return prioritizedAutocompletionSuggestions(suggestions: Array(suggestions), for: trimmedQuery)
}

private func prioritizedAutocompletionSuggestions(suggestions: [OmnibarSuggestion], for query: String) -> [OmnibarSuggestion] {
    guard let preferred = omnibarPreferredAutocompletionSuggestionIndex(
        suggestions: suggestions,
        query: query
    ) else {
        return suggestions
    }

    guard preferred != 0 else { return suggestions }

    var reordered = suggestions
    let suggestion = reordered.remove(at: preferred)
    reordered.insert(suggestion, at: 0)
    return reordered
}

func omnibarPreferredAutocompletionSuggestionIndex(
    suggestions: [OmnibarSuggestion],
    query: String
) -> Int? {
    guard !query.isEmpty else { return nil }

    var candidates: [(idx: Int, suffixLength: Int)] = []
    for (idx, suggestion) in suggestions.enumerated() {
        guard omnibarSuggestionSupportsAutocompletion(query: query, suggestion: suggestion) else { continue }
        guard let completion = omnibarSuggestionCompletion(for: suggestion) else { continue }
        let displayCompletion = omnibarSuggestionMatchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: omnibarSuggestionTitle(for: suggestion)
        ) ? completion : ""
        guard !displayCompletion.isEmpty else { continue }

        let suffixLength = max(
            0,
            omnibarSuggestionDisplayText(forPrefixing: displayCompletion, query: query).utf16.count - query.utf16.count
        )
        candidates.append((idx: idx, suffixLength: suffixLength))
    }

    guard let preferred = candidates.min(by: {
        if $0.suffixLength != $1.suffixLength {
            return $0.suffixLength < $1.suffixLength
        }
        return $0.idx < $1.idx
    })?.idx else {
        return nil
    }

    return preferred
}

private func omnibarSuggestionDisplayText(forPrefixing completion: String, query: String) -> String {
    let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
    let typedIncludesWWWPrefix = query.hasPrefix("www.")
    if typedIncludesScheme {
        return completion
    }
    if typedIncludesWWWPrefix {
        return stripHTTPSchemePrefix(completion)
    }
    return stripHTTPSchemeAndWWWPrefix(completion)
}

func staleOmnibarRemoteSuggestionsForDisplay(
    query: String,
    previousRemoteQuery: String,
    previousRemoteSuggestions: [String],
    limit: Int = 8
) -> [String] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPreviousQuery = previousRemoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let loweredQuery = trimmedQuery.lowercased()
    let loweredPreviousQuery = trimmedPreviousQuery.lowercased()
    guard !trimmedQuery.isEmpty, !trimmedPreviousQuery.isEmpty else { return [] }
    guard loweredQuery == loweredPreviousQuery || loweredQuery.hasPrefix(loweredPreviousQuery) || loweredPreviousQuery.hasPrefix(loweredQuery) else {
        return []
    }
    guard !previousRemoteSuggestions.isEmpty else { return [] }
    let sanitized = previousRemoteSuggestions.compactMap { raw -> String? in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    if sanitized.isEmpty {
        return []
    }
    return Array(sanitized.prefix(limit))
}

func omnibarInlineCompletionForDisplay(
    typedText: String,
    suggestions: [OmnibarSuggestion],
    isFocused: Bool,
    selectionRange: NSRange,
    hasMarkedText: Bool
) -> OmnibarInlineCompletion? {
    guard isFocused else { return nil }
    guard !hasMarkedText else { return nil }

    let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let loweredQuery = query.lowercased()
    let typedIncludesScheme = loweredQuery.hasPrefix("https://") || loweredQuery.hasPrefix("http://")
    let typedIncludesWWWPrefix = loweredQuery.hasPrefix("www.")
    let queryCount = query.utf16.count

    let urlCandidate = suggestions.first { suggestion in
        guard let completion = omnibarSuggestionCompletion(for: suggestion) else { return false }
        return omnibarSuggestionMatchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: omnibarSuggestionTitle(for: suggestion)
        )
    }
    guard let candidate = urlCandidate else {
        return nil
    }

    let acceptedText = candidate.completion
    let displayText: String
    if typedQueryHasExplicitPathOrQuery(query) {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = stripHTTPSchemePrefix(acceptedText)
        } else {
            displayText = stripHTTPSchemeAndWWWPrefix(acceptedText)
        }
    } else if let hostOnlyDisplay = inlineCompletionHostDisplayText(
        for: acceptedText,
        typedIncludesScheme: typedIncludesScheme,
        typedIncludesWWWPrefix: typedIncludesWWWPrefix
    ) {
        displayText = hostOnlyDisplay
    } else {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = stripHTTPSchemePrefix(acceptedText)
        } else {
            displayText = stripHTTPSchemeAndWWWPrefix(acceptedText)
        }
    }

    guard omnibarSuggestionSupportsAutocompletion(query: query, suggestion: candidate) else { return nil }
    // The display text must start with the typed query so the inline completion
    // visually extends what the user typed rather than replacing it (e.g. a
    // history entry matched via title "localhost:3000" whose URL is google.com
    // should not replace a typed "l" with "g").
    guard displayText.lowercased().hasPrefix(loweredQuery) else { return nil }
    guard displayText.utf16.count > queryCount else {
        return nil
    }

    let displayCount = displayText.utf16.count

    let resolvedSelectionRange: NSRange = {
        if selectionRange.location == NSNotFound {
            return NSRange(location: queryCount, length: 0)
        }
        let clampedLocation = min(selectionRange.location, displayCount)
        let remaining = max(0, displayCount - clampedLocation)
        let clampedLength = min(selectionRange.length, remaining)
        return NSRange(location: clampedLocation, length: clampedLength)
    }()

    let suffixRange = NSRange(location: queryCount, length: max(0, displayCount - queryCount))
    let isCaretAtTypedBoundary = (resolvedSelectionRange.length == 0 && resolvedSelectionRange.location == queryCount)
    let isSuffixSelection = NSEqualRanges(resolvedSelectionRange, suffixRange)
    let isSelectAllSelection = (resolvedSelectionRange.location == 0 && resolvedSelectionRange.length == displayCount)
    // Command+A can briefly report just the typed prefix selection before the full
    // select-all range lands. Keep inline completion alive through that transition.
    let typedPrefixSelection = NSRange(location: 0, length: queryCount)
    let isTypedPrefixSelection = NSEqualRanges(resolvedSelectionRange, typedPrefixSelection)
    guard isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection else {
        return nil
    }

    return OmnibarInlineCompletion(typedText: query, displayText: displayText, acceptedText: acceptedText)
}

func omnibarDesiredSelectionRangeForInlineCompletion(
    currentSelection: NSRange,
    inlineCompletion: OmnibarInlineCompletion
) -> NSRange {
    let typedCount = inlineCompletion.typedText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let displayCount = inlineCompletion.displayText.utf16.count
    let isSelectAll = currentSelection.location == 0 && currentSelection.length == displayCount
    if isSelectAll ||
        NSEqualRanges(currentSelection, inlineCompletion.suffixRange) ||
        NSEqualRanges(currentSelection, typedPrefixSelection) {
        return currentSelection
    }
    return inlineCompletion.suffixRange
}

func omnibarPublishedBufferTextForFieldChange(
    fieldValue: String,
    inlineCompletion: OmnibarInlineCompletion?,
    selectionRange: NSRange?,
    hasMarkedText: Bool
) -> String {
    guard !hasMarkedText else { return fieldValue }
    guard let inlineCompletion else { return fieldValue }
    guard fieldValue == inlineCompletion.displayText else { return fieldValue }
    guard let selectionRange else { return inlineCompletion.typedText }

    let typedCount = inlineCompletion.typedText.utf16.count
    let displayCount = inlineCompletion.displayText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let isCaretAtTypedBoundary = selectionRange.location == typedCount && selectionRange.length == 0
    let isSuffixSelection = NSEqualRanges(selectionRange, inlineCompletion.suffixRange)
    let isSelectAllSelection = selectionRange.location == 0 && selectionRange.length == displayCount
    let isTypedPrefixSelection = NSEqualRanges(selectionRange, typedPrefixSelection)
    if isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection {
        return inlineCompletion.typedText
    }

    return fieldValue
}

func omnibarInlineCompletionIfBufferMatchesTypedPrefix(
    bufferText: String,
    inlineCompletion: OmnibarInlineCompletion?
) -> OmnibarInlineCompletion? {
    guard let inlineCompletion else { return nil }
    guard bufferText == inlineCompletion.typedText else { return nil }
    return inlineCompletion
}

private func typedQueryHasExplicitPathOrQuery(_ typedQuery: String) -> Bool {
    var normalized = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized.contains("/") || normalized.contains("?") || normalized.contains("#")
}

private func inlineCompletionHostDisplayText(
    for acceptedText: String,
    typedIncludesScheme: Bool,
    typedIncludesWWWPrefix: Bool
) -> String? {
    guard let components = URLComponents(string: acceptedText),
          var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !host.isEmpty else {
        return nil
    }

    if !typedIncludesWWWPrefix, host.hasPrefix("www.") {
        host.removeFirst("www.".count)
    }

    let portSuffix: String
    if let port = components.port {
        let scheme = components.scheme?.lowercased()
        let isDefaultPort =
            (scheme == "https" && port == 443) ||
            (scheme == "http" && port == 80)
        portSuffix = isDefaultPort ? "" : ":\(port)"
    } else {
        portSuffix = ""
    }

    let hostWithPort = "\(host)\(portSuffix)"
    if typedIncludesScheme {
        let scheme = (components.scheme?.lowercased() == "http") ? "http" : "https"
        return "\(scheme)://\(hostWithPort)"
    }
    return hostWithPort
}

private func stripHTTPSchemePrefix(_ raw: String) -> String {
    var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized
}

private func stripHTTPSchemeAndWWWPrefix(_ raw: String) -> String {
    var normalized = stripHTTPSchemePrefix(raw)
    if normalized.hasPrefix("www.") {
        normalized.removeFirst("www.".count)
    }
    return normalized
}

struct OmnibarPillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct BrowserAddressBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Omnibar State Machine

struct OmnibarState: Equatable {
    var isFocused: Bool = false
    var currentURLString: String = ""
    var buffer: String = ""
    var suggestions: [OmnibarSuggestion] = []
    var selectedSuggestionIndex: Int = 0
    var selectedSuggestionID: String?
    var isUserEditing: Bool = false
}

enum OmnibarEvent: Equatable {
    case focusGained(currentURLString: String)
    case focusLostRevertBuffer(currentURLString: String)
    case focusLostPreserveBuffer(currentURLString: String)
    case panelURLChanged(currentURLString: String)
    case bufferChanged(String)
    case suggestionsUpdated([OmnibarSuggestion])
    case moveSelection(delta: Int)
    case highlightIndex(Int)
    case escape
}

struct OmnibarEffects: Equatable {
    var shouldSelectAll: Bool = false
    var shouldBlurToWebView: Bool = false
    var shouldRefreshSuggestions: Bool = false
}

@discardableResult
func omnibarReduce(state: inout OmnibarState, event: OmnibarEvent) -> OmnibarEffects {
    var effects = OmnibarEffects()

    switch event {
    case .focusGained(let url):
        state.isFocused = true
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        effects.shouldSelectAll = true

    case .focusLostRevertBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil

    case .focusLostPreserveBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil

    case .panelURLChanged(let url):
        state.currentURLString = url
        if !state.isUserEditing {
            state.buffer = url
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
        }

    case .bufferChanged(let newValue):
        state.buffer = newValue
        if state.isFocused {
            state.isUserEditing = (newValue != state.currentURLString)
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            effects.shouldRefreshSuggestions = true
        }

    case .suggestionsUpdated(let items):
        let previousItems = state.suggestions
        let previousSelectedID = state.selectedSuggestionID
        state.suggestions = items
        if items.isEmpty {
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
        } else if let previousSelectedID,
                  let existingIdx = items.firstIndex(where: { $0.id == previousSelectedID }) {
            state.selectedSuggestionIndex = existingIdx
            state.selectedSuggestionID = items[existingIdx].id
        } else if let preferredSuggestionIndex = omnibarPreferredAutocompletionSuggestionIndex(
            suggestions: items,
            query: state.buffer
        ) {
            state.selectedSuggestionIndex = preferredSuggestionIndex
            state.selectedSuggestionID = items[preferredSuggestionIndex].id
        } else if previousItems.isEmpty {
            // Popup reopened: start keyboard focus from the first row.
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = items[0].id
        } else if let previousSelectedID,
                  let idx = items.firstIndex(where: { $0.id == previousSelectedID }) {
            state.selectedSuggestionIndex = idx
            state.selectedSuggestionID = items[idx].id
        } else {
            state.selectedSuggestionIndex = min(max(0, state.selectedSuggestionIndex), items.count - 1)
            state.selectedSuggestionID = items[state.selectedSuggestionIndex].id
        }

    case .moveSelection(let delta):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(
            max(0, state.selectedSuggestionIndex + delta),
            state.suggestions.count - 1
        )
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id

    case .highlightIndex(let idx):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(max(0, idx), state.suggestions.count - 1)
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id

    case .escape:
        guard state.isFocused else { break }
        // Chrome semantics:
        // - If user input is in progress OR the popup is open: revert to the page URL and select-all.
        // - Otherwise: exit omnibar focus.
        if state.isUserEditing || !state.suggestions.isEmpty {
            state.isUserEditing = false
            state.buffer = state.currentURLString
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            effects.shouldSelectAll = true
        } else {
            effects.shouldBlurToWebView = true
        }
    }

    return effects
}

struct OmnibarSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case search(engineName: String, query: String)
        case navigate(url: String)
        case history(url: String, title: String?)
        case switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?)
        case remote(query: String)
    }

    let kind: Kind

    // Stable identity prevents row teardown/rebuild flicker while typing.
    var id: String {
        switch kind {
        case .search(let engineName, let query):
            return "search|\(engineName.lowercased())|\(query.lowercased())"
        case .navigate(let url):
            return "navigate|\(url.lowercased())"
        case .history(let url, _):
            return "history|\(url.lowercased())"
        case .switchToTab(let tabId, let panelId, let url, _):
            return "switch-tab|\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
        case .remote(let query):
            return "remote|\(query.lowercased())"
        }
    }

    var completion: String {
        switch kind {
        case .search(_, let q): return q
        case .navigate(let url): return url
        case .history(let url, _): return url
        case .switchToTab(_, _, let url, _): return url
        case .remote(let q): return q
        }
    }

    var primaryText: String {
        switch kind {
        case .search(let engineName, let q):
            return "Search \(engineName) for \"\(q)\""
        case .navigate(let url):
            return Self.displayURLText(for: url)
        case .history(let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .remote(let q):
            return q
        }
    }

    var listText: String {
        switch kind {
        case .history(let url, let title), .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            guard !titleOneline.isEmpty else { return Self.displayURLText(for: url) }
            return "\(titleOneline) — \(Self.displayURLText(for: url))"
        default:
            return primaryText
        }
    }

    var secondaryText: String? {
        switch kind {
        case .history(let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        default:
            return nil
        }
    }

    var trailingBadgeText: String? {
        switch kind {
        case .switchToTab:
            return String(localized: "browser.switchToTab", defaultValue: "Switch to tab")
        default:
            return nil
        }
    }

    var isHistoryRemovable: Bool {
        if case .history = kind { return true }
        return false
    }

    static func history(_ entry: BrowserHistoryStore.Entry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    static func history(url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: url, title: title))
    }

    static func search(engineName: String, query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .search(engineName: engineName, query: query))
    }

    static func navigate(url: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .navigate(url: url))
    }

    static func switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .switchToTab(tabId: tabId, panelId: panelId, url: url, title: title))
    }

    private static func singleLineText(_ value: String?) -> String {
        var normalized = (value ?? "").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("  ") {
            let collapsed = normalized.replacingOccurrences(of: "  ", with: " ")
            if collapsed == normalized { break }
            normalized = collapsed
        }
        return normalized
    }

    static func remoteSearchSuggestion(_ query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .remote(query: query))
    }

    private static func displayURLText(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              var host = components.host else {
            return rawURL
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        host = host.lowercased()

        var result = host
        if let port = components.port {
            result += ":\(port)"
        }

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            result += path
        } else if path == "/" {
            result += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?\(query)"
        }

        if result.isEmpty { return rawURL }
        return result
    }
}
