import XCTest
import Darwin
@testable import AppProxyKit

final class SessionTests: XCTestCase {
    func testSessionUsesPrivatePermissionsAndCleansCredentials() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let attrs = try FileManager.default.attributesOfItem(atPath: session.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let requestURL = session.url.appendingPathComponent("request.json")
        let requestAttrs = try FileManager.default.attributesOfItem(atPath: requestURL.path)
        XCTAssertEqual((requestAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let request = try session.readRequest(consuming: false)
        XCTAssertEqual(request.ownerUID, getuid())
        XCTAssertEqual(request.parentPID, getpid())
        _ = try session.readRequest(consuming: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        try session.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.url.path))
    }
    func testHeartbeatAndStopAreTokenBound() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let request = try session.readRequest(consuming: false)
        XCTAssertNil(try session.stopReason(token: request.token, now: Date(), maximumHeartbeatAge: 10))
        XCTAssertEqual(try session.stopReason(token: request.token, now: Date().addingTimeInterval(11), maximumHeartbeatAge: 10), .staleHeartbeat)
        try session.requestStop()
        XCTAssertEqual(try session.stopReason(token: request.token, now: Date(), maximumHeartbeatAge: 10), .requested)
    }
    func testRequestSymlinkAndHardlinkAreRejectedWithoutReadingTarget() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let requestURL = session.url.appendingPathComponent("request.json")
        let target = session.url.appendingPathComponent("private-target")
        try FileManager.default.moveItem(at: requestURL, to: target)
        try FileManager.default.createSymbolicLink(at: requestURL, withDestinationURL: target)
        XCTAssertThrowsError(try session.readRequest(consuming: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.removeItem(at: requestURL)
        try FileManager.default.linkItem(at: target, to: requestURL)
        XCTAssertThrowsError(try session.readRequest(consuming: false))
    }
    func testStatusReplacementDoesNotFollowSymlink() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let target = session.url.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: session.url.appendingPathComponent("status.json"), withDestinationURL: target)
        try session.writeStatus(SessionStatus(phase: .failed, message: "Synthetic failure", restoration: "unchanged"))
        XCTAssertEqual(try String(contentsOf: target), "keep")
        XCTAssertEqual(try session.readStatus()?.phase, .failed)
    }
    func testReopeningRejectsInsecureDirectoryAndNonSessionPath() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        XCTAssertNoThrow(try SessionDirectory.open(url: session.url, ownerUID: getuid()))
        XCTAssertThrowsError(try SessionDirectory.open(url: URL(fileURLWithPath: "/tmp/" + UUID().uuidString), ownerUID: getuid()))
        XCTAssertEqual(chmod(session.url.path, 0o755), 0)
        XCTAssertThrowsError(try SessionDirectory.open(url: session.url, ownerUID: getuid()))
    }
    func testMalformedOrOverlargeRequestFailsClosed() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let path = session.url.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: path)
        XCTAssertThrowsError(try session.readRequest(consuming: false))
        try Data(repeating: 32, count: 1_048_577).write(to: path)
        XCTAssertThrowsError(try session.readRequest(consuming: false))
    }
    func testHelperRejectsUnexpectedArgumentsWithoutConsumingRequest() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/AppProxyHelper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build AppProxyHelper first") }
        for arguments in [["check", "--session", session.url.path, "--exec", "/bin/true"], ["run", "--session", session.url.path], ["check", "--session", "/tmp/arbitrary"]] {
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0)
        }
        XCTAssertNoThrow(try session.readRequest(consuming: false))
    }

    func testConsumingMalformedRequestStillRemovesCredentialFile() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? session.cleanup() }
        let path = session.url.appendingPathComponent("request.json")
        try Data("{bad credential-bearing request".utf8).write(to: path)
        XCTAssertThrowsError(try session.readRequest(consuming: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testSnapshotComparisonReportsUnknownAndChangedState() {
        let before = NetworkSnapshot(values: ["dns": "a", "routes.ipv4": "route"])
        XCTAssertTrue(before.matches(NetworkSnapshot(values: before.values)))
        XCTAssertTrue(before.comparison(to: NetworkSnapshot(values: ["dns": "b", "routes.ipv4": "route"])).contains("DNS"))
        let missing = NetworkSnapshot(values: ["dns": "<unavailable>"])
        XCTAssertFalse(missing.matches(missing))
        XCTAssertTrue(missing.comparison(to: missing).contains("incomplete"))
    }
    func testBundledHelperChecksCoreWithoutConsumingRequestAndRejectsTampering() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("downloaded-binaries/sing-box")
        guard FileManager.default.fileExists(atPath: binary.path) else { throw XCTSkip("Download pinned core to exercise bundled check") }
        let socks = ProxyProfile(name: "SOCKS check", kind: .socks5, host: "127.0.0.1", port: 1080, username: "synthetic-user", hasPassword: true)
        let http = ProxyProfile(name: "HTTP check", kind: .http, host: "127.0.0.1", port: 8080)
        let rule = ApplicationRule(name: "Check app", appPath: "/Applications/Check +.app", executablePath: "/Applications/Check +.app/Contents/MacOS/check", proxyID: socks.id)
        var exactRule = rule; exactRule.id = UUID(); exactRule.proxyID = http.id; exactRule.includeHelpers = false
        let configuration = AppConfiguration(proxies: [socks, http], rules: [rule, exactRule])
        let session = try SessionDirectory.create(configuration: configuration, passwords: [socks.id.uuidString: "synthetic-password"])
        defer { try? session.cleanup() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let contents = temporary.appendingPathComponent("App Proxy.app/Contents")
        let helper = contents.appendingPathComponent("MacOS/AppProxyHelper")
        let core = contents.appendingPathComponent("Resources/sing-box")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(".build/debug/AppProxyHelper"), to: helper)
        try FileManager.default.copyItem(at: binary, to: core)
        func check() throws -> Int32 {
            let process = Process(); process.executableURL = helper; process.arguments = ["check", "--session", session.url.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        XCTAssertEqual(try check(), 0)
        XCTAssertNoThrow(try session.readRequest(consuming: false))
        try Data("tampered".utf8).write(to: core)
        XCTAssertNotEqual(try check(), 0)
        XCTAssertNoThrow(try session.readRequest(consuming: false))
        XCTAssertEqual(try session.readStatus()?.phase, .failed)
    }

    func testRouteComparisonIgnoresNeighborsExpirationAndRowOrder() {
        let initial = """
        Routing tables
        Internet:
        Destination Gateway Flags Netif Expire
        default 192.0.2.1 UGScg en0
        192.0.2.1 aa:bb:cc:dd:ee:ff UHLWIir en0 1199
        192.0.2/24 link#14 UCS en0 !
        """
        let after = """
        Destination Gateway Flags Netif Expire
        192.0.2/24 link#14 UCS en0
        default 192.0.2.1 UGScg en0
        """
        XCTAssertEqual(NetworkSnapshot.normalizeRoutes(initial), NetworkSnapshot.normalizeRoutes(after))
        XCTAssertNotEqual(NetworkSnapshot.normalizeRoutes(initial), NetworkSnapshot.normalizeRoutes(after.replacingOccurrences(of: "192.0.2.1", with: "192.0.2.254")))
    }

    func testAbandonedCleanupPreservesLiveParentAndLiveCore() throws {
        let active = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        let abandoned = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        let liveCore = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        defer { try? active.cleanup(); try? abandoned.cleanup(); try? liveCore.cleanup() }
        let requestPath = abandoned.url.appendingPathComponent("request.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: requestPath)) as? [String: Any])
        object["parentPID"] = Int32.max
        try JSONSerialization.data(withJSONObject: object).write(to: requestPath)
        _ = try liveCore.readRequest(consuming: true)
        try liveCore.writeStatus(SessionStatus(phase: .failed, message: "needs investigation", corePID: getpid()))
        _ = try SessionDirectory.cleanupAbandoned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveCore.url.path))
    }

    func testOpeningSymlinkedSessionDirectoryIsRejected() throws {
        let session = try SessionDirectory.create(configuration: AppConfiguration(), passwords: [:])
        let moved = session.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: session.url)
            try? FileManager.default.moveItem(at: moved, to: session.url)
            try? session.cleanup()
        }
        try FileManager.default.moveItem(at: session.url, to: moved)
        try FileManager.default.createSymbolicLink(at: session.url, withDestinationURL: moved)
        XCTAssertThrowsError(try SessionDirectory.open(url: session.url, ownerUID: getuid()))
    }

    func testActualReadOnlySnapshotQueriesComplete() {
        let before = NetworkSnapshot.capture()
        XCTAssertEqual(Set(before.values.keys), Set(["routes.ipv4", "routes.ipv6", "dns", "system.proxy"]))
        XCTAssertFalse(before.values.values.contains("<unavailable>"))
        XCTAssertTrue(before.matches(before))
    }

}
