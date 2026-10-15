import XCTest
@testable import AppProxyKit

final class StorageTests: XCTestCase {
    func testKeychainCreateUpdateReadDelete() throws {
        let secrets = KeychainSecrets(service: "com.mrongm.app-proxy.tests." + UUID().uuidString)
        let id = UUID()
        defer { try? secrets.delete(id) }
        XCTAssertNil(try secrets.read(id))
        try secrets.save("ephemeral-fixture-one", for: id)
        XCTAssertEqual(try secrets.read(id), "ephemeral-fixture-one")
        try secrets.save("ephemeral-fixture-two", for: id)
        XCTAssertEqual(try secrets.read(id), "ephemeral-fixture-two")
        try secrets.delete(id)
        XCTAssertNil(try secrets.read(id))
    }
    func testSelectRealBundleAndRejectSharedExternalExecutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Example.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "Example", "CFBundleName": "Example", "CFBundleIdentifier": "test.example", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Example")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let rule = try AppSelection.rule(for: app, proxyID: UUID())
        XCTAssertEqual(rule.name, "Example")
        XCTAssertEqual(rule.executablePath, executable.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(try AppSelection.rule(for: dir, proxyID: UUID()))
    }
}
