import Foundation
import Darwin

public struct LocalUpstreamOwner: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    let startedSeconds: Int64
    let startedMicroseconds: Int64
    let uid: UInt32
}

public struct LocalUpstreamPlan: Sendable {
    public let owners: [LocalUpstreamOwner]
    public var processPaths: [String] { Array(Set(owners.map(\.executablePath))).sorted() }
    public var bundlePaths: [String] { Array(Set(processPaths.compactMap(LocalUpstream.enclosingBundle))).sorted() }
    public static let empty = LocalUpstreamPlan(owners: [])
    public func validateOwners() throws {
        for owner in owners {
            guard (try? LocalUpstream.processIdentity(pid: owner.pid)) == owner else {
                throw AppProxyError(localized: "local.owner_changed")
            }
        }
    }
}

struct LocalListener {
    let pid: Int32
    let family: Int32
    let address: String
    let port: Int
}

/// Discovers only local TCP listeners used by enabled rules. Does not open a TUN or change networking.
public enum LocalUpstream {
    public static func resolve(configuration: AppConfiguration, cancellationCheck: () throws -> Void = {}) throws -> LocalUpstreamPlan {
        try configuration.validate()
        try cancellationCheck()
        let used = Set(configuration.rules.filter(\.enabled).map(\.proxyID))
        let interfaces = try localInterfaceAddresses()
        var owners: [Int32: LocalUpstreamOwner] = [:]
        var listenersByPort: [Int: [LocalListener]] = [:]
        for profile in configuration.proxies where used.contains(profile.id) {
            try cancellationCheck()
            let addresses = try resolveAddresses(profile.host)
            guard !addresses.contains("0.0.0.0"), !addresses.contains("::") else { throw AppProxyError(localized: "local.unspecified") }
            let local = addresses.filter { address in
                address.hasPrefix("127.") || address == "::1" || interfaces.contains(address)
            }
            var foundLocalListener = false
            for address in local {
                let listeners: [LocalListener]
                if let cached = listenersByPort[profile.port] { listeners = cached }
                else {
                    listeners = try Self.listeners(port: profile.port)
                    listenersByPort[profile.port] = listeners
                }
                var pids = matchingPIDs(listeners, address: address, port: profile.port)
                if pids.isEmpty, canonicalAddress(address)?.family == AF_INET {
                    let candidates = Set(listeners.filter {
                        $0.port == profile.port && $0.family == AF_INET6 && ($0.address == "*" || $0.address == "::")
                    }.map(\.pid))
                    if !candidates.isEmpty {
                        // lsof omits IPV6_V6ONLY. Verify identities, then prove this local IPv4 endpoint accepts TCP.
                        for candidate in candidates { _ = try processIdentity(pid: candidate) }
                        if try probeLocalIPv4(address: address, port: profile.port, cancellationCheck: cancellationCheck) { pids = candidates }
                    }
                }
                if !pids.isEmpty { foundLocalListener = true }
                for pid in pids { owners[pid] = try processIdentity(pid: pid) }
            }
            guard local.isEmpty || foundLocalListener else { throw AppProxyError(localized: "local.listener_missing") }
        }
        let plan = LocalUpstreamPlan(owners: owners.values.sorted { $0.pid < $1.pid })
        try plan.validateOwners()
        return plan
    }

    public static func processIdentity(pid: Int32) throws -> LocalUpstreamOwner {
        func processInfo() throws -> kinfo_proc {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
            guard pid > 0, sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
                  size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid,
                  info.kp_proc.p_stat != SZOMB else { throw AppProxyError(localized: "local.identity") }
            return info
        }
        let before = try processInfo()
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { throw AppProxyError(localized: "local.executable") }
        let path = String(cString: bytes)
        let after = try processInfo()
        let firstStart = before.kp_proc.p_un.__p_starttime
        let lastStart = after.kp_proc.p_un.__p_starttime
        guard firstStart.tv_sec == lastStart.tv_sec, firstStart.tv_usec == lastStart.tv_usec,
              before.kp_eproc.e_ucred.cr_uid == after.kp_eproc.e_ucred.cr_uid,
              path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              path.rangeOfCharacter(from: .controlCharacters) == nil else { throw AppProxyError(localized: "local.identity_changed") }
        return LocalUpstreamOwner(pid: pid, executablePath: path, startedSeconds: Int64(lastStart.tv_sec), startedMicroseconds: Int64(lastStart.tv_usec), uid: after.kp_eproc.e_ucred.cr_uid)
    }

    public static func enclosingBundle(executablePath: String) -> String? {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components.prefix(index + 1)))
    }

    static func parseListeners(_ text: String) -> [LocalListener] {
        var pid: Int32?
        var family: Int32?
        var records: [LocalListener] = []
        for line in text.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = String(line.dropFirst())
            switch kind {
            case "p": pid = Int32(value); family = nil
            case "f": family = nil
            case "t": family = value == "IPv4" ? AF_INET : value == "IPv6" ? AF_INET6 : nil
            case "n":
                guard let pid, pid > 0, let family, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { continue }
                var address = String(value[..<colon])
                if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
                guard address == "*" || canonicalAddress(address)?.family == family else { continue }
                records.append(LocalListener(pid: pid, family: family, address: address == "*" ? address : canonicalAddress(address)!.value, port: port))
            default: break
            }
        }
        return records
    }

    static func matchingPIDs(_ listeners: [LocalListener], address: String, port: Int) -> Set<Int32> {
        guard let endpoint = canonicalAddress(address) else { return [] }
        return Set(listeners.filter {
            $0.port == port && $0.family == endpoint.family &&
            ($0.address == endpoint.value || $0.address == "*" || $0.address == "0.0.0.0" || $0.address == "::")
        }.map(\.pid))
    }

    /// Called only for addresses already identified as local; sends no application data.
    private static func probeLocalIPv4(address: String, port: Int, cancellationCheck: () throws -> Void) throws -> Bool {
        try cancellationCheck()
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        let result = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { try cancellationCheck(); return true }
        guard [EINPROGRESS, EWOULDBLOCK, EINTR].contains(errno) else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try cancellationCheck()
            let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
            let milliseconds = Int32(min(100, (remaining + 999_999) / 1_000_000))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 { if errno == EINTR { continue }; return false }
            if ready == 0 { continue }
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            let queried = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
            try cancellationCheck()
            return queried == 0 && error == 0 && descriptor.revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0
        }
        return false
    }

    private static func canonicalAddress(_ address: String) -> (value: String, family: Int32)? {
        let pieces = address.split(separator: "%", maxSplits: 1).map(String.init)
        let host = pieces.first ?? ""
        var ipv4 = in_addr(); var ipv6 = in6_addr(); var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return (String(cString: buffer), AF_INET)
        }
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            let raw = withUnsafeBytes(of: ipv6) { Array($0) }
            if raw.prefix(10).allSatisfy({ $0 == 0 }), raw[10] == 255, raw[11] == 255 {
                return (raw.suffix(4).map(String.init).joined(separator: "."), AF_INET)
            }
            var value = String(cString: buffer)
            if pieces.count == 2 {
                let zone = UInt32(pieces[1]) ?? if_nametoindex(pieces[1])
                guard zone > 0 else { return nil }; value += "%" + String(zone)
            }
            return (value, AF_INET6)
        }
        return nil
    }

    private static func addressString(_ address: UnsafePointer<sockaddr>) -> String? {
        guard [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return canonicalAddress(String(cString: buffer))?.value
    }

    private static func localInterfaceAddresses() throws -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw AppProxyError(localized: "local.interfaces") }
        defer { freeifaddrs(first) }
        var result = Set<String>(); var next = first
        while let current = next {
            if let address = current.pointee.ifa_addr, let value = addressString(UnsafePointer(address)) { result.insert(value) }
            next = current.pointee.ifa_next
        }
        return result
    }

    private static func resolveAddresses(_ host: String) throws -> Set<String> {
        if let numeric = canonicalAddress(host) { return [numeric.value] }
        let result = DiscoveryOutput<Set<String>>()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
            var first: UnsafeMutablePointer<addrinfo>?
            let code = getaddrinfo(host, nil, &hints, &first)
            defer { if first != nil { freeaddrinfo(first) }; finished.signal() }
            guard code == 0 else { return }
            var addresses = Set<String>(); var next = first
            while let current = next {
                if let address = current.pointee.ai_addr, let value = addressString(UnsafePointer(address)) { addresses.insert(value) }
                next = current.pointee.ai_next
            }
            result.set(addresses)
        }
        guard finished.wait(timeout: .now() + 4) == .success, let addresses = result.get(), !addresses.isEmpty else { throw AppProxyError(localized: "local.resolve") }
        return addresses
    }

    private static func listeners(port: Int) throws -> [LocalListener] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpftn"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe
        let output = DiscoveryOutput<Data>(); let finished = DispatchSemaphore(value: 0)
        do { try process.run() } catch { throw AppProxyError(localized: "local.query") }
        DispatchQueue.global().async {
            var data = Data(); var oversized = false
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if data.count + chunk.count <= 1_048_576 { data.append(chunk) } else { oversized = true }
            }
            if !oversized { output.set(data) }; finished.signal()
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard finished.wait(timeout: .now() + 1) == .success, !timedOut,
              [0, 1].contains(process.terminationStatus), let data = output.get() else { throw AppProxyError(localized: "local.query_output") }
        return parseListeners(String(decoding: data, as: UTF8.self))
    }
}

private final class DiscoveryOutput<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}
