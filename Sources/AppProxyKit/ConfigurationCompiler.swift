import Foundation

public enum ConfigurationCompiler {
    /// Contains runtime credentials. Never log or persist this data outside a private session.
    public static func compile(_ configuration: AppConfiguration, passwords: [String: String], corePath: String = "/app-proxy-runtime/sing-box", directProcessPaths: [String] = [], directBundlePaths: [String] = []) throws -> Data {
        try configuration.validate()
        var outbounds: [[String: Any]] = [["type": "direct", "tag": "direct"]]
        for p in configuration.proxies {
            var out: [String: Any] = ["type": p.kind == .socks5 ? "socks" : "http", "tag": p.tag, "server": p.host, "server_port": p.port, "connect_timeout": "10s"]
            if p.kind == .socks5 { out["version"] = "5" }
            if !p.username.isEmpty { out["username"] = p.username }
            if p.hasPassword {
                guard let secret = passwords[p.id.uuidString], !secret.isEmpty, secret.utf8.count <= 4096 else { throw AppProxyError(localized: "error.proxy.password_missing", arguments: [p.name]) }
                guard p.kind != .socks5 || secret.utf8.count <= 255 else { throw AppProxyError(localized: "error.proxy.socks_password", arguments: [p.name]) }
                out["password"] = secret
            }
            outbounds.append(out)
        }
        let paths = Array(Set([corePath] + directProcessPaths)).sorted()
        let patterns = Set(directBundlePaths).sorted().map { "^" + NSRegularExpression.escapedPattern(for: $0) + "/.*$" }
        var bypass: [String: Any] = ["process_path": paths, "action": "route", "outbound": "direct"]
        if !patterns.isEmpty {
            bypass = ["type": "logical", "mode": "or", "rules": [["process_path": paths], ["process_path_regex": patterns]], "action": "route", "outbound": "direct"]
        }
        var rules: [[String: Any]] = [
            bypass,
            ["port": [53], "action": "route", "outbound": "direct"]
        ]
        for r in configuration.rules where r.enabled {
            guard let proxyID = r.proxyID, let proxy = configuration.proxies.first(where: { $0.id == proxyID }) else { throw AppProxyError(localized: "error.rule.proxy_required") }
            let match: [String: Any] = r.includeHelpers ? ["process_path_regex": [r.bundlePattern]] : ["process_path": [r.executablePath]]
            var udp = match; udp["network"] = "udp"; udp["action"] = "reject"
            var tcp = match; tcp["network"] = "tcp"; tcp["action"] = "route"
            tcp["outbound"] = proxy.tag
            rules.append(udp); rules.append(tcp)
        }
        let json: [String: Any] = [
            "log": ["level": "info", "timestamp": true, "disabled": false],
            "inbounds": [["type": "tun", "tag": "app-proxy-tun", "address": ["172.29.199.1/30", "fd7a:115c:a1e0::1/126"], "mtu": 1500, "auto_route": true, "dns_mode": "disabled", "stack": "system"]],
            "outbounds": outbounds,
            "route": ["rules": rules, "final": "direct", "auto_detect_interface": true, "find_process": true]
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}

public enum LogSanitizer {
    public static func redact(_ text: String, configuration: AppConfiguration, passwords: [String]) -> String {
        var output = text
        let credentials = passwords + configuration.proxies.map(\.username)
        // Streaming logs are sanitized one line at a time, including multiline credentials.
        let raw = (credentials + credentials.flatMap { $0.components(separatedBy: .newlines) }).filter { !$0.isEmpty }
        var variants = Set(raw)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for value in raw {
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) { variants.insert(encoded) }
            if let data = try? JSONEncoder().encode(value), let quoted = String(data: data, encoding: .utf8) {
                let escaped = String(quoted.dropFirst().dropLast())
                variants.insert(escaped); variants.insert(escaped.replacingOccurrences(of: "\\/", with: "/"))
                variants.insert(escaped.replacingOccurrences(of: "/", with: "\\/"))
            }
        }
        for p in configuration.proxies where !p.username.isEmpty {
            for password in passwords { variants.insert(Data((p.username + ":" + password).utf8).base64EncodedString()) }
        }
        let sensitive = variants.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        for value in sensitive { output = output.replacingOccurrences(of: value, with: "<redacted>") }
        output = output.replacingOccurrences(of: "\u{1B}", with: "")
        return String(output.prefix(2048))
    }
}
