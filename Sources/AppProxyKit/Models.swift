import Foundation

public struct AppProxyError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
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
    public var proxyID: UUID
    public var enabled: Bool
    public var includeHelpers: Bool
    public init(id: UUID = UUID(), name: String, appPath: String, executablePath: String, proxyID: UUID, enabled: Bool = true, includeHelpers: Bool = true) {
        self.id = id; self.name = name; self.appPath = appPath; self.executablePath = executablePath
        self.proxyID = proxyID; self.enabled = enabled; self.includeHelpers = includeHelpers
    }
    public var bundlePattern: String { "^" + NSRegularExpression.escapedPattern(for: appPath) + "/.*$" }
    public func matches(path: String) -> Bool {
        enabled && (includeHelpers ? path.hasPrefix(appPath + "/") : path == executablePath)
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var proxies: [ProxyProfile]
    public var rules: [ApplicationRule]
    public init(proxies: [ProxyProfile] = [], rules: [ApplicationRule] = []) { self.proxies = proxies; self.rules = rules }
    public func validate() throws {
        guard version == 1, proxies.count <= 128, rules.count <= 256 else { throw AppProxyError("配置版本或数量无效") }
        guard Set(proxies.map(\.id)).count == proxies.count, Set(rules.map(\.id)).count == rules.count else { throw AppProxyError("配置含重复 ID") }
        for p in proxies {
            guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, p.name.utf8.count <= 200 else { throw AppProxyError("代理名称不能为空或超过 200 字节") }
            guard !p.host.isEmpty, p.host.utf8.count <= 253,
                  p.host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  !p.host.contains("/"), !p.host.contains("@"), !p.host.contains("["), !p.host.contains("]"),
                  !p.host.contains("://"), (1...65535).contains(p.port) else { throw AppProxyError("代理主机或端口无效：主机不含协议/路径，端口 1–65535") }
            guard p.username.utf8.count <= 255, p.username.rangeOfCharacter(from: .controlCharacters) == nil else { throw AppProxyError("用户名无效") }
            guard !p.hasPassword || !p.username.isEmpty else { throw AppProxyError("设置密码时必须填写用户名") }
        }
        for r in rules {
            guard proxies.contains(where: { $0.id == r.proxyID }) else { throw AppProxyError("应用规则引用的代理不存在") }
            let url = URL(fileURLWithPath: r.appPath)
            guard r.appPath.hasPrefix("/"), url.pathExtension == "app", url.standardizedFileURL.path == r.appPath,
                  !r.appPath.contains("\n"), r.appPath.utf8.count <= 4096,
                  r.executablePath.hasPrefix(r.appPath + "/"), URL(fileURLWithPath: r.executablePath).standardizedFileURL.path == r.executablePath else { throw AppProxyError("应用路径无效，请重新选择 .app") }
        }
    }
    public func match(path: String) -> ApplicationRule? { rules.first { $0.matches(path: path) } }
    public mutating func removeProxy(id: UUID) throws {
        guard !rules.contains(where: { $0.proxyID == id }) else { throw AppProxyError("请先删除或调整引用此代理的应用规则") }
        proxies.removeAll { $0.id == id }
    }
}
