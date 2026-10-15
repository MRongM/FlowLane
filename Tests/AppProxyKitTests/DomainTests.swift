import XCTest
@testable import AppProxyKit

final class DomainTests: XCTestCase {
    func profile() -> ProxyProfile { ProxyProfile(name: "Test", kind: .socks5, host: "127.0.0.1", port: 1080) }
    func rule(_ p: ProxyProfile) -> ApplicationRule {
        ApplicationRule(name: "Mail +", appPath: "/Applications/Mail +.app", executablePath: "/Applications/Mail +.app/Contents/MacOS/Mail", proxyID: p.id)
    }
    func testRejectsInvalidProfilesAndMissingProxy() throws {
        var p = profile()
        for host in ["", "a b", "https://proxy.example", "x\nfoo", "user@host"] {
            p.host = host
            XCTAssertThrowsError(try AppConfiguration(proxies: [p]).validate())
        }
        p = profile(); p.port = 65536
        XCTAssertThrowsError(try AppConfiguration(proxies: [p]).validate())
        p = profile()
        XCTAssertThrowsError(try AppConfiguration(rules: [rule(p)]).validate())
        XCTAssertThrowsError(try AppConfiguration(proxies: [p, p]).validate())
    }
    func testHelperMatchingIsAnchoredAndEscaped() throws {
        let r = rule(profile())
        XCTAssertTrue(r.matches(path: r.executablePath))
        XCTAssertTrue(r.matches(path: r.appPath + "/Contents/Frameworks/Mail Helper.app/Contents/MacOS/Helper"))
        XCTAssertFalse(r.matches(path: "/Applications/Mail X.app/Contents/MacOS/Mail"))
        XCTAssertFalse(r.matches(path: "/System/Library/Frameworks/WebKit.framework/WebKit.Networking"))
        XCTAssertFalse(r.matches(path: r.appPath + "Evil/child"))
        var exact = r; exact.includeHelpers = false
        XCTAssertFalse(exact.matches(path: r.appPath + "/Contents/XPCServices/helper"))
    }
    func testCompilerPreservesOrderRejectsUDPAndDefaultsDirect() throws {
        let p = profile(); var disabled = rule(p); disabled.enabled = false
        let r = rule(p)
        let c = AppConfiguration(proxies: [p], rules: [disabled, r])
        let data = try ConfigurationCompiler.compile(c, passwords: [:])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds[1]["type"] as? String, "socks")
        let route = try XCTUnwrap(json["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "direct")
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 4) // core direct, DNS direct, app UDP reject, app TCP
        XCTAssertEqual(rules[1]["port"] as? [Int], [53])
        XCTAssertEqual(rules[2]["action"] as? String, "reject")
        XCTAssertEqual(rules[2]["network"] as? String, "udp")
        XCTAssertEqual(rules[3]["outbound"] as? String, p.tag)
        let tun = try XCTUnwrap((json["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(tun["dns_mode"] as? String, "disabled")
        XCTAssertEqual((tun["address"] as? [String])?.count, 2)
    }
    func testCredentialsOnlyAppearInRuntimeAndRequiredSecretsFailClosed() throws {
        var p = profile(); p.username = "test-user"; p.hasPassword = true
        let c = AppConfiguration(proxies: [p], rules: [rule(p)])
        XCTAssertThrowsError(try ConfigurationCompiler.compile(c, passwords: [:]))
        let stored = try JSONEncoder().encode(c)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("synthetic-secret"))
        let generated = try ConfigurationCompiler.compile(c, passwords: [p.id.uuidString: "synthetic-secret"])
        XCTAssertTrue(String(decoding: generated, as: UTF8.self).contains("synthetic-secret"))
        XCTAssertFalse(LogSanitizer.redact("failed synthetic-secret test-user", configuration: c, passwords: ["synthetic-secret"]).contains("synthetic-secret"))
    }
    func testLogRedactionCoversEscapedAndBasicAuthentication() throws {
        var p = profile(); p.username = "fixture-user"
        let secret = "a\"b/c+ d"
        let basic = Data((p.username + ":" + secret).utf8).base64EncodedString()
        let text = "password=a\\\"b\\/c+ d encoded=a%22b%2Fc%2B%20d Basic " + basic
        let result = LogSanitizer.redact(text, configuration: AppConfiguration(proxies: [p]), passwords: [secret])
        XCTAssertFalse(result.contains(basic))
        XCTAssertFalse(result.contains("a%22b%2Fc%2B%20d"))
        XCTAssertFalse(result.contains("a\\\"b\\/c+ d"))
        let splitLine = LogSanitizer.redact("first-line", configuration: AppConfiguration(), passwords: ["first-line\nsecond-line"])
        XCTAssertEqual(splitLine, "<redacted>")
    }
    func testPersistenceRoundTripAndPrivatePermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(directory: folder)
        let p = profile(); let c = AppConfiguration(proxies: [p], rules: [rule(p)])
        try store.save(c)
        XCTAssertEqual(try store.load(), c)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("{bad json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }
    func testPriorityAndDeleteReferencedProxy() throws {
        let p = profile(); var second = profile(); second.name = "Second"
        var r2 = rule(second); r2.id = UUID()
        var c = AppConfiguration(proxies: [p, second], rules: [rule(p), r2])
        XCTAssertEqual(c.match(path: rule(p).executablePath)?.proxyID, p.id)
        c.rules.swapAt(0, 1)
        XCTAssertEqual(c.match(path: rule(p).executablePath)?.proxyID, second.id)
        XCTAssertThrowsError(try c.removeProxy(id: p.id))
    }
    func testStateMachineCancellationCrashAndStop() throws {
        var state = RuntimeStateMachine()
        XCTAssertThrowsError(try state.apply(.ready))
        try state.apply(.start); XCTAssertEqual(state.phase, .starting)
        try state.apply(.failure("管理员授权已取消")); XCTAssertEqual(state.phase, .failed)
        try state.apply(.start); try state.apply(.ready); XCTAssertEqual(state.phase, .running)
        try state.apply(.stop); XCTAssertEqual(state.phase, .stopping)
        try state.apply(.finished); XCTAssertEqual(state.phase, .stopped)
        try state.apply(.start); try state.apply(.failure("内核退出"))
        XCTAssertEqual(state.message, "内核退出")
    }
    func testSOCKS5PasswordUsesProtocolByteLimit() throws {
        var p = profile(); p.username = "fixture"; p.hasPassword = true
        let c = AppConfiguration(proxies: [p])
        XCTAssertNoThrow(try ConfigurationCompiler.compile(c, passwords: [p.id.uuidString: String(repeating: "x", count: 255)]))
        XCTAssertThrowsError(try ConfigurationCompiler.compile(c, passwords: [p.id.uuidString: String(repeating: "x", count: 256)]))
        XCTAssertThrowsError(try ConfigurationCompiler.compile(c, passwords: [p.id.uuidString: String(repeating: "密", count: 86)]))
        p.kind = .http
        XCTAssertNoThrow(try ConfigurationCompiler.compile(AppConfiguration(proxies: [p]), passwords: [p.id.uuidString: String(repeating: "x", count: 256)]))
    }
    func testLocalUpstreamExemptionPrecedesSelectedRules() throws {
        let p = profile(); let r = rule(p)
        let data = try ConfigurationCompiler.compile(AppConfiguration(proxies: [p], rules: [r]), passwords: [:], directProcessPaths: ["/local/proxy", "/local/proxy"], directBundlePaths: [r.appPath])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(json["route"] as? [String: Any])
        let first = try XCTUnwrap((route["rules"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["outbound"] as? String, "direct")
        XCTAssertEqual(first["type"] as? String, "logical")
        XCTAssertEqual(first["mode"] as? String, "or")
        let predicates = try XCTUnwrap(first["rules"] as? [[String: Any]])
        XCTAssertEqual(predicates[0]["process_path"] as? [String], ["/app-proxy-runtime/sing-box", "/local/proxy"])
        XCTAssertEqual(predicates[1]["process_path_regex"] as? [String], [r.bundlePattern])
    }
    func testActualCoreAcceptsProductExemptionAndEscapedBundle() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let core = repo.appendingPathComponent("downloaded-binaries/sing-box")
        guard FileManager.default.isExecutableFile(atPath: core.path) else { throw XCTSkip("先运行 scripts/fetch-core.sh") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let p = profile(); let r = rule(p)
        let data = try ConfigurationCompiler.compile(AppConfiguration(proxies: [p], rules: [r]), passwords: [:], directProcessPaths: ["/local/proxy"], directBundlePaths: [r.appPath])
        let file = folder.appendingPathComponent("config.json")
        try SecureFiles.write(data, to: file)
        let process = Process(); process.executableURL = core; process.arguments = ["check", "-c", file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
