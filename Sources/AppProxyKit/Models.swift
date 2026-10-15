import Foundation

public struct AppProxyError: LocalizedError, Equatable {
    public let content: LocalizedMessage
    public var message: String { content.rendered(in: .en) }
    public init(_ message: String) { content = .verbatim(message) }
    public init(content: LocalizedMessage) { self.content = content }
    public init(localized key: String, arguments: [String] = []) { content = LocalizedMessage(key, arguments: arguments) }
    public var errorDescription: String? { message }
}

public enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case socks5, http
    public var title: String { self == .socks5 ? "SOCKS5" : "HTTP CONNECT" }
}

public struct ProxyProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String
    public var hasPassword: Bool
    public var tag: String { "proxy-" + id.uuidString.lowercased() }
    public init(id: UUID = UUID(), name: String, kind: ProxyKind, host: String, port: Int, username: String = "", hasPassword: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port
        self.username = username; self.hasPassword = hasPassword
    }
}

public struct ApplicationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var appPath: String
    public var executablePath: String
    public var proxyID: UUID?
    public var enabled: Bool
    public var includeHelpers: Bool
    public init(id: UUID = UUID(), name: String, appPath: String, executablePath: String, proxyID: UUID?, enabled: Bool = true, includeHelpers: Bool = true) {
        self.id = id; self.name = name; self.appPath = appPath; self.executablePath = executablePath
        self.proxyID = proxyID; self.enabled = enabled; self.includeHelpers = includeHelpers
    }
    public var bundlePattern: String { "^" + NSRegularExpression.escapedPattern(for: appPath) + "/.*$" }
    public func matches(path: String) -> Bool {
        enabled && proxyID != nil && (includeHelpers ? path.hasPrefix(appPath + "/") : path == executablePath)
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var proxies: [ProxyProfile]
    public var rules: [ApplicationRule]
    public init(proxies: [ProxyProfile] = [], rules: [ApplicationRule] = []) { self.proxies = proxies; self.rules = rules }
    public func validate() throws {
        guard version == 1, proxies.count <= 128, rules.count <= 256 else { throw AppProxyError(localized: "error.config.limit") }
        guard Set(proxies.map(\.id)).count == proxies.count, Set(rules.map(\.id)).count == rules.count else { throw AppProxyError(localized: "error.config.duplicate") }
        for p in proxies {
            guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, p.name.utf8.count <= 200 else { throw AppProxyError(localized: "error.proxy.name") }
            guard !p.host.isEmpty, p.host.utf8.count <= 253,
                  p.host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  !p.host.contains("/"), !p.host.contains("@"), !p.host.contains("["), !p.host.contains("]"),
                  !p.host.contains("://"), (1...65535).contains(p.port) else { throw AppProxyError(localized: "error.proxy.endpoint") }
            guard p.username.utf8.count <= 255, p.username.rangeOfCharacter(from: .controlCharacters) == nil else { throw AppProxyError(localized: "error.proxy.username") }
            guard !p.hasPassword || !p.username.isEmpty else { throw AppProxyError(localized: "error.proxy.username_required") }
        }
        for r in rules {
            if let proxyID = r.proxyID {
                guard proxies.contains(where: { $0.id == proxyID }) else { throw AppProxyError(localized: "error.rule.proxy_missing") }
            } else {
                guard !r.enabled else { throw AppProxyError(localized: "error.rule.proxy_required") }
            }
            let url = URL(fileURLWithPath: r.appPath)
            guard r.appPath.hasPrefix("/"), url.pathExtension == "app", url.standardizedFileURL.path == r.appPath,
                  !r.appPath.contains("\n"), r.appPath.utf8.count <= 4096,
                  r.executablePath.hasPrefix(r.appPath + "/"), URL(fileURLWithPath: r.executablePath).standardizedFileURL.path == r.executablePath else { throw AppProxyError(localized: "error.application.path") }
        }
    }
    public func match(path: String) -> ApplicationRule? { rules.first { $0.matches(path: path) } }
    public mutating func removeProxy(id: UUID) throws {
        guard !rules.contains(where: { $0.proxyID == id }) else { throw AppProxyError(localized: "error.proxy.in_use") }
        proxies.removeAll { $0.id == id }
    }
}
