import XCTest
import Darwin
@testable import AppProxyKit

final class LocalUpstreamTests: XCTestCase {
    private func listener() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard queried == 0 else { close(fd); throw POSIXError(.EIO) }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }
    private func ipv6WildcardListener(v6Only: Bool) throws -> (Int32, Int) {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var only: Int32 = v6Only ? 1 : 0
        guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(fd); throw POSIXError(.EIO) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let queried = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard queried == 0 else { close(fd); throw POSIXError(.EIO) }
        return (fd, Int(UInt16(bigEndian: address.sin6_port)))
    }
    private func configuration(host: String, port: Int) -> AppConfiguration {
        let profile = ProxyProfile(name: "Local", kind: .socks5, host: host, port: port)
        let rule = ApplicationRule(name: "App", appPath: "/Applications/Test.app", executablePath: "/Applications/Test.app/Contents/MacOS/Test", proxyID: profile.id)
        return AppConfiguration(proxies: [profile], rules: [rule])
    }
    func testActualLoopbackListenerDiscoversNativeOwnerAndIdentity() throws {
        let (fd, port) = try listener(); defer { close(fd) }
        let plan = try LocalUpstream.resolve(configuration: configuration(host: "127.0.0.1", port: port))
        XCTAssertEqual(plan.owners.map(\.pid), [getpid()])
        XCTAssertEqual(plan.processPaths, [try LocalUpstream.processIdentity(pid: getpid()).executablePath])
        XCTAssertNoThrow(try plan.validateOwners())
    }
    func testMissingLocalListenerFailsClosed() throws {
        let (fd, port) = try listener(); close(fd)
        XCTAssertThrowsError(try LocalUpstream.resolve(configuration: configuration(host: "127.0.0.1", port: port)))
    }
    func testRemoteAddressNeedsNoLocalProcessExemption() throws {
        let plan = try LocalUpstream.resolve(configuration: configuration(host: "203.0.113.9", port: 12438))
        XCTAssertTrue(plan.owners.isEmpty); XCTAssertTrue(plan.processPaths.isEmpty); XCTAssertTrue(plan.bundlePaths.isEmpty)
    }
    func testParserMatchesExactAddressesAndFamilySpecificWildcards() throws {
        let output = "p11\nf3\ntIPv4\nn127.0.0.2:1080\nf4\ntIPv4\nn*:1080\np12\nf5\ntIPv6\nn[::1]:1080\np13\nf6\ntIPv6\nn*:1080\n"
        let listeners = LocalUpstream.parseListeners(output)
        XCTAssertEqual(LocalUpstream.matchingPIDs(listeners, address: "127.0.0.1", port: 1080), Set([11]))
        XCTAssertEqual(LocalUpstream.matchingPIDs(listeners, address: "::1", port: 1080), Set([12, 13]))
        XCTAssertEqual(LocalUpstream.matchingPIDs(listeners, address: "::2", port: 1080), Set([13]))
        XCTAssertTrue(LocalUpstream.matchingPIDs(listeners, address: "127.0.0.1", port: 1081).isEmpty)
        let exactOnly = LocalUpstream.parseListeners("p11\nf3\ntIPv4\nn127.0.0.2:1080\n")
        XCTAssertTrue(LocalUpstream.matchingPIDs(exactOnly, address: "127.0.0.1", port: 1080).isEmpty)
    }
    func testIPv6AndAppBundleNormalization() {
        XCTAssertEqual(LocalUpstream.enclosingBundle(executablePath: "/Applications/Proxy.app/Contents/Frameworks/Proxy Helper.app/Contents/MacOS/Helper"), "/Applications/Proxy.app")
        XCTAssertNil(LocalUpstream.enclosingBundle(executablePath: "/usr/local/bin/proxy"))
        let listeners = LocalUpstream.parseListeners("p42\nf8\ntIPv6\nn[0:0:0:0:0:0:0:1]:1080\n")
        XCTAssertEqual(LocalUpstream.matchingPIDs(listeners, address: "::1", port: 1080), Set([42]))
    }
    func testUnresolvableHostFailsBeforeActivation() {
        XCTAssertThrowsError(try LocalUpstream.resolve(configuration: configuration(host: "not a host", port: 1080)))
    }
    func testLocalhostWithOnlyIPv4ListenerStillDiscoversOwner() throws {
        let (fd, port) = try listener(); defer { close(fd) }
        let plan = try LocalUpstream.resolve(configuration: configuration(host: "localhost", port: port))
        XCTAssertEqual(plan.owners.map(\.pid), [getpid()])
    }
    func testOwnerExitInvalidatesLivePlan() throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["20"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let plan = LocalUpstreamPlan(owners: [try LocalUpstream.processIdentity(pid: child.processIdentifier)])
        XCTAssertNoThrow(try plan.validateOwners())
        child.terminate(); child.waitUntilExit()
        XCTAssertThrowsError(try plan.validateOwners())
    }
    func testUnusedOfflineLocalProfileDoesNotBlockSession() throws {
        var unused = configuration(host: "127.0.0.1", port: 12438)
        unused.rules = []
        XCTAssertTrue(try LocalUpstream.resolve(configuration: unused).owners.isEmpty)
    }
    func testIPv4MappedLoopbackDiscoversLocalOwner() throws {
        let (fd, port) = try listener(); defer { close(fd) }
        let plan = try LocalUpstream.resolve(configuration: configuration(host: "::ffff:127.0.0.1", port: port))
        XCTAssertEqual(plan.owners.map(\.pid), [getpid()])
    }

    func testNativeDualStackWildcardListenerAcceptsIPv4Upstream() throws {
        let (fd, port) = try ipv6WildcardListener(v6Only: false); defer { close(fd) }
        let plan = try LocalUpstream.resolve(configuration: configuration(host: "127.0.0.1", port: port))
        XCTAssertEqual(plan.owners.map(\.pid), [getpid()])
        XCTAssertNoThrow(try plan.validateOwners())
    }
    func testNativeIPv6OnlyWildcardDoesNotExemptIPv4Upstream() throws {
        let (fd, port) = try ipv6WildcardListener(v6Only: true); defer { close(fd) }
        XCTAssertThrowsError(try LocalUpstream.resolve(configuration: configuration(host: "127.0.0.1", port: port)))
    }

    func testIPv4ListenerDoesNotExemptUnrelatedIPv6OnlyProcess() throws {
        let (fd, port) = try listener(); defer { close(fd) }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM); s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1); s.bind(('::',int(sys.argv[1]))); s.listen(4); print('ready',flush=True); sys.stdin.read()", String(port)]
        let output = Pipe(); let input = Pipe()
        child.standardOutput = output; child.standardInput = input; child.standardError = FileHandle.nullDevice
        try child.run(); defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(ready, Data("ready\n".utf8))
        let plan = try LocalUpstream.resolve(configuration: configuration(host: "127.0.0.1", port: port))
        XCTAssertEqual(plan.owners.map(\.pid), [getpid()])
        XCTAssertFalse(plan.owners.contains(where: { $0.pid == child.processIdentifier }))
    }

}
