import Foundation

// MARK: - Remote/User Proxy Settings

enum BrowserUserProxySettings {
    static let hostKey = "browserUserProxyHost"
    static let portKey = "browserUserProxyPort"
    static let typeKey = "browserUserProxyType"

    enum ProxyType: String {
        case socks5
        case httpConnect
    }

    struct Descriptor {
        let host: String
        let port: Int
        let proxyType: ProxyType
    }

    /// Returns the user-configured proxy descriptor, or nil when no valid proxy is set.
    static func descriptor(defaults: UserDefaults = .standard) -> Descriptor? {
        guard let host = defaults.string(forKey: hostKey) else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }
        // Use object(forKey:) check so that port == 0 stored as a real value is still caught.
        guard defaults.object(forKey: portKey) != nil else { return nil }
        let port = defaults.integer(forKey: portKey)
        guard port >= 1 && port <= 65535 else { return nil }
        let typeRaw = defaults.string(forKey: typeKey) ?? ProxyType.socks5.rawValue
        guard let proxyType = ProxyType(rawValue: typeRaw) else { return nil }
        return Descriptor(host: trimmedHost, port: port, proxyType: proxyType)
    }
}
