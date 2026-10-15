import XCTest
import AppProxyKit
@testable import AppProxy

final class RuntimeControllerTests: XCTestCase {
    @MainActor func testConfigurationCheckFailurePreservesLocalizedHelperMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(directory: dir)
        let p = ProxyProfile(name: "Fixture", kind: .http, host: "127.0.0.1", port: 1080)
        let rule = ApplicationRule(name: "Fixture", appPath: "/Applications/Fixture.app", executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture", proxyID: p.id)
        store.change { $0 = AppConfiguration(proxies: [p], rules: [rule]) }
        let helperMessage = LocalizedMessage("helper.check.failed")
        let runtime = RuntimeController(makeCommand: { _, args in
            do {
                let session = try SessionDirectory.open(url: URL(fileURLWithPath: args[2]), ownerUID: getuid())
                try session.writeStatus(SessionStatus(phase: .failed, content: helperMessage))
            } catch { XCTFail("Could not create helper metadata fixture") }
            return CommandProcess(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }, reachability: { _ in })
        runtime.start(store: store)
        for _ in 0..<100 where runtime.active { try await Task.sleep(nanoseconds: 20_000_000) }
        let expected = LocalizedMessage("error.config_check", values: [helperMessage], table: .interface)
        XCTAssertEqual(runtime.state.content.rendered(in: .zhHans), expected.rendered(in: .zhHans))
        XCTAssertEqual(runtime.state.content.rendered(in: .fr), expected.rendered(in: .fr))
    }
    @MainActor func testStopCancelsPendingAuthorizationAndCleansSession() async throws {
        try await exerciseCancellation(quitting: false)
    }
    @MainActor func testQuitCancelsPendingAuthorization() async throws {
        try await exerciseCancellation(quitting: true)
    }
    @MainActor private func exerciseCancellation(quitting: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(directory: dir)
        let p = ProxyProfile(name: "Fixture", kind: .socks5, host: "127.0.0.1", port: 1080)
        let rule = ApplicationRule(name: "Fixture", appPath: "/Applications/Fixture.app", executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture", proxyID: p.id)
        store.change { $0 = AppConfiguration(proxies: [p], rules: [rule]) }
        var authorization: CommandProcess?
        let controller = RuntimeController(makeCommand: { url, _ in
            let authorizing = url.lastPathComponent == "osascript"
            let command = CommandProcess(executable: URL(fileURLWithPath: authorizing ? "/bin/sleep" : "/usr/bin/true"), arguments: authorizing ? ["30"] : [])
            if authorizing { authorization = command }
            return command
        }, reachability: { _ in })
        controller.start(store: store)
        for _ in 0..<100 where authorization?.isRunning != true { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(authorization?.isRunning, true)
        XCTAssertEqual(controller.state.phase, .starting)
        if quitting { controller.shutdown() } else { controller.stop() }
        for _ in 0..<100 where controller.active { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(controller.active)
        XCTAssertEqual(controller.state.phase, .stopped)
        XCTAssertEqual(authorization?.isRunning, false)
        authorization?.cancel()
    }
    @MainActor func testUnreachableProxyFailsBeforeAuthorization() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(directory: dir)
        let p = ProxyProfile(name: "Fixture", kind: .http, host: "127.0.0.1", port: 1080)
        let rule = ApplicationRule(name: "Fixture", appPath: "/Applications/Fixture.app", executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture", proxyID: p.id)
        store.change { $0 = AppConfiguration(proxies: [p], rules: [rule]) }
        var launched = false
        let runtime = RuntimeController(makeCommand: { _, _ in
            launched = true; return CommandProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }, reachability: { _ in throw AppProxyError("上游不可达 fixture") })
        runtime.start(store: store)
        for _ in 0..<100 where runtime.active { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(launched); XCTAssertEqual(runtime.state.phase, .failed)
        XCTAssertEqual(runtime.state.message, "上游不可达 fixture")
    }
    @MainActor func testSOCKSByteLimitRejectsBeforeKeychainWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(directory: dir)
        let p = ProxyProfile(name: "Fixture", kind: .socks5, host: "127.0.0.1", port: 1080, username: "fixture", hasPassword: true)
        defer { try? store.secrets.delete(p.id) }
        XCTAssertThrowsError(try store.saveProfile(p, password: String(repeating: "x", count: 256), keepPassword: false))
        XCTAssertNil(try store.secrets.read(p.id)); XCTAssertTrue(store.configuration.proxies.isEmpty)
        try store.saveProfile(p, password: String(repeating: "x", count: 255), keepPassword: false)
        XCTAssertEqual(try store.secrets.read(p.id)?.utf8.count, 255)
    }
}
