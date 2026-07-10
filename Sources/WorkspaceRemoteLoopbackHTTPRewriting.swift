// Extracted from WorkspaceRemoteDaemon.swift (nuclear-review #98): HTTP request/response rewriting for the loopback proxy alias host.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

struct WorkspaceRemoteLoopbackProxyRoute: Equatable {
    let targetHost: String
    let rewriteAliasHost: String?
}

enum WorkspaceRemoteLoopbackPolicy {
    static let canonicalAliasHost = "cmux-loopback.localtest.me"

    private static let legacyAliasHosts: Set<String> = [
        "programa-loopback.localtest.me",
    ]
    private static let acceptedAliasHosts = legacyAliasHosts.union([canonicalAliasHost])
    private static let sourceHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
    ]

    static func browserAliasURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? ""),
              sourceHosts.contains(host) else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = canonicalAliasHost
        return components?.url
    }

    static func displayURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? ""),
              acceptedAliasHosts.contains(host) else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "localhost"
        return components?.url ?? url
    }

    static func proxyRoute(for host: String) -> WorkspaceRemoteLoopbackProxyRoute {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard acceptedAliasHosts.contains(normalized) else {
            return WorkspaceRemoteLoopbackProxyRoute(targetHost: host, rewriteAliasHost: nil)
        }
        return WorkspaceRemoteLoopbackProxyRoute(
            targetHost: "127.0.0.1",
            rewriteAliasHost: normalized
        )
    }
}

enum RemoteLoopbackHTTPRequestRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"
    private static let requestLineMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "PRI"]

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        rewriteIfNeeded(data: data, aliasHost: aliasHost, allowIncompleteHeadersAtEOF: false)
    }

    static func rewriteIfNeeded(data: Data, aliasHost: String, allowIncompleteHeadersAtEOF: Bool) -> Data {
        let headerData: Data
        let remainder: Data

        if let headerRange = data.range(of: headerDelimiter) {
            headerData = Data(data[..<headerRange.upperBound])
            remainder = Data(data[headerRange.upperBound...])
        } else if allowIncompleteHeadersAtEOF {
            headerData = data
            remainder = Data()
        } else {
            return data
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        guard let requestLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard requestLineLooksHTTP(lines[requestLineIndex]) else { return data }

        let rewrittenRequestLine = rewriteRequestLine(lines[requestLineIndex], aliasHost: aliasHost)
        if rewrittenRequestLine != lines[requestLineIndex] {
            lines[requestLineIndex] = rewrittenRequestLine
        }

        for index in (requestLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + remainder
    }

    private static func requestLineLooksHTTP(_ requestLine: String) -> Bool {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        return requestLineMethods.contains(method)
    }

    private static func rewriteRequestLine(_ requestLine: String, aliasHost: String) -> String {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return requestLine }

        var components = URLComponents(string: String(parts[1]))
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return requestLine
        }
        components?.host = canonicalLoopbackHost
        guard let rewrittenURL = components?.string else { return requestLine }

        var rewritten = parts
        rewritten[1] = Substring(rewrittenURL)
        let leadingTrivia = requestLine.prefix { $0.isWhitespace || $0.isNewline }
        let trailingTrivia = String(requestLine.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leadingTrivia) + rewritten.joined(separator: " ") + trailingTrivia
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "host":
            guard let rewrittenHost = rewriteHostValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenHost)"
        case "origin", "referer":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        default:
            return line
        }
    }

    private static func rewriteHostValue(_ value: String, aliasHost: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            guard BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
                return nil
            }
            let remainder = String(trimmed[closing...].dropFirst())
            return canonicalLoopbackHost + remainder
        }

        if let colonIndex = trimmed.lastIndex(of: ":"), !trimmed[..<colonIndex].contains(":") {
            let host = String(trimmed[..<colonIndex])
            guard BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
                return nil
            }
            return canonicalLoopbackHost + trimmed[colonIndex...]
        }

        guard BrowserInsecureHTTPSettings.normalizeHost(trimmed) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        return canonicalLoopbackHost
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        components?.host = canonicalLoopbackHost
        return components?.string
    }
}

struct RemoteLoopbackHTTPRequestStreamRewriter {
    private static let maxHeaderBytes = 64 * 1024
    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let aliasHost: String
    private var pendingHeaderBytes = Data()
    private var hasForwardedHeaders = false

    init(aliasHost: String) {
        self.aliasHost = aliasHost
    }

    mutating func rewriteNextChunk(_ data: Data, eof: Bool) -> Data {
        guard !hasForwardedHeaders else { return data }

        pendingHeaderBytes.append(data)
        if pendingHeaderBytes.count > Self.maxHeaderBytes {
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        guard pendingHeaderBytes.range(of: Self.headerDelimiter) != nil else {
            guard eof else { return Data() }
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        hasForwardedHeaders = true
        let payload = pendingHeaderBytes
        pendingHeaderBytes = Data()
        return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: payload,
            aliasHost: aliasHost
        )
    }
}

enum RemoteLoopbackHTTPResponseRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        guard let headerRange = data.range(of: headerDelimiter) else { return data }
        let headerData = Data(data[..<headerRange.upperBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard lines[statusLineIndex].uppercased().hasPrefix("HTTP/") else { return data }

        for index in (statusLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + data[headerRange.upperBound...]
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "location", "content-location", "origin", "referer", "access-control-allow-origin":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        case "set-cookie":
            guard let rewrittenCookie = rewriteCookieValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenCookie)"
        default:
            return line
        }
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(canonicalLoopbackHost) else {
            return nil
        }
        components?.host = aliasHost
        return components?.string
    }

    private static func rewriteCookieValue(_ value: String, aliasHost: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        var didRewrite = false
        let rewrittenParts = parts.map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("domain=") else { return part }
            let domainValue = String(trimmed.dropFirst("domain=".count))
            guard BrowserInsecureHTTPSettings.normalizeHost(domainValue) == BrowserInsecureHTTPSettings.normalizeHost(canonicalLoopbackHost) else {
                return part
            }
            didRewrite = true
            let leadingWhitespace = part.prefix { $0.isWhitespace }
            return "\(leadingWhitespace)Domain=\(aliasHost)"
        }

        return didRewrite ? rewrittenParts.joined(separator: ";") : nil
    }
}
