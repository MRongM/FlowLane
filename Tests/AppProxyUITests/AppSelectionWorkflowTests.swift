import XCTest
import AppProxyKit
@testable import AppProxy

final class AppSelectionWorkflowTests: XCTestCase {
    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    @MainActor func testCanSelectRealApplicationBeforeAnyProxyAndReloadDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        XCTAssertTrue(store.loaded); XCTAssertTrue(store.configuration.proxies.isEmpty)
        store.addApplications([textEdit])
        XCTAssertNil(store.error)
        let rule = try XCTUnwrap(store.configuration.rules.first)
        XCTAssertEqual(store.configuration.rules.count, 1)
        XCTAssertEqual(rule.appPath, textEdit.path)
        XCTAssertNil(rule.proxyID); XCTAssertFalse(rule.enabled)
        let reloaded = AppStore(directory: directory)
        XCTAssertTrue(reloaded.loaded); XCTAssertEqual(reloaded.configuration, store.configuration)
    }

    @MainActor func testAssigningAndClearingProxyControlsPendingRuleActivation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        store.addApplications([textEdit])
        let ruleID = try XCTUnwrap(store.configuration.rules.first?.id)
        let first = ProxyProfile(name: "First", kind: .socks5, host: "127.0.0.1", port: 1080)
        let second = ProxyProfile(name: "Second", kind: .http, host: "127.0.0.1", port: 8080)
        store.change { $0.proxies = [first, second] }
        store.assignProxy(first.id, to: ruleID)
        XCTAssertNil(store.error); XCTAssertEqual(store.configuration.rules.first?.proxyID, first.id)
        XCTAssertEqual(store.configuration.rules.first?.enabled, true)
        store.change { $0.rules[0].enabled = false }
        store.assignProxy(second.id, to: ruleID)
        XCTAssertEqual(store.configuration.rules.first?.enabled, false)
        store.assignProxy(nil, to: ruleID)
        XCTAssertNil(store.configuration.rules.first?.proxyID)
        XCTAssertEqual(store.configuration.rules.first?.enabled, false)
        XCTAssertEqual(AppStore(directory: directory).configuration, store.configuration)
    }

    @MainActor func testSelectingWithExistingProxyAssignsFirstAndEnables() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let proxy = ProxyProfile(name: "Existing", kind: .http, host: "127.0.0.1", port: 8080)
        store.change { $0.proxies.append(proxy) }
        store.addApplications([textEdit])
        XCTAssertNil(store.error); XCTAssertEqual(store.configuration.rules.first?.proxyID, proxy.id)
        XCTAssertEqual(store.configuration.rules.first?.enabled, true)
    }

    @MainActor func testInvalidConfigurationRemainsUntouchedBySelectionOrAssignment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("configuration.json")
        let broken = Data("{invalid original config".utf8)
        try broken.write(to: path)
        let store = AppStore(directory: directory)
        XCTAssertFalse(store.loaded)
        store.addApplications([textEdit])
        store.assignProxy(nil, to: UUID())
        store.deleteProfile(UUID())
        XCTAssertEqual(try Data(contentsOf: path), broken)
        XCTAssertTrue(store.configuration.rules.isEmpty)
    }

    @MainActor func testAllPendingRulesCannotStartOrRequestAuthorization() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        store.addApplications([textEdit])
        var launched = false
        let runtime = RuntimeController(makeCommand: { _, _ in
            launched = true
            return CommandProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }, reachability: { _ in })
        runtime.start(store: store)
        XCTAssertFalse(launched)
        XCTAssertEqual(runtime.state.phase, .failed)
    }
}
