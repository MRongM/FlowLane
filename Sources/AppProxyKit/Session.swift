import Foundation
import Darwin

public struct SessionRequest: Codable, Sendable {
    public let configuration: AppConfiguration
    public let passwords: [String: String]
    public let parentPID: Int32
    public let ownerUID: UInt32
    public let token: String
}

public struct SessionStatus: Codable, Sendable {
    public var phase: RuntimePhase
    public var message: String
    public var corePID: Int32?
    public var logs: [String]
    public var restoration: String?
    public var messageContent: LocalizedMessage?
    public var restorationContent: LocalizedMessage?
    public init(phase: RuntimePhase, message: String, corePID: Int32? = nil, logs: [String] = [], restoration: String? = nil) {
        self.phase = phase; self.message = message; self.corePID = corePID
        self.logs = logs; self.restoration = restoration
        messageContent = nil; restorationContent = nil
    }
    public init(phase: RuntimePhase, content: LocalizedMessage, corePID: Int32? = nil, logs: [String] = [], restorationContent: LocalizedMessage? = nil) {
        self.phase = phase; messageContent = content; message = content.rendered(in: .en)
        self.corePID = corePID; self.logs = logs; self.restorationContent = restorationContent
        restoration = restorationContent?.rendered(in: .en)
    }
}

public enum SessionStopReason: String, Equatable { case requested, staleHeartbeat }
private struct SessionHeartbeat: Codable { var token: String; var timestamp: TimeInterval }

/// A pinned directory descriptor is the security boundary; child paths are never followed.
public final class SessionDirectory {
    public let url: URL
    public let ownerUID: UInt32
    private let fd: Int32
    private let parentFD: Int32
    private var token: String?
    private init(url: URL, ownerUID: UInt32, fd: Int32, parentFD: Int32, token: String? = nil) {
        self.url = url; self.ownerUID = ownerUID; self.fd = fd; self.parentFD = parentFD; self.token = token
    }
    deinit { Darwin.close(fd); Darwin.close(parentFD) }

    public static func create(configuration: AppConfiguration, passwords: [String: String]) throws -> SessionDirectory {
        try configuration.validate()
        // Compile before writing a request so missing/invalid secrets never reach authorization.
        _ = try ConfigurationCompiler.compile(configuration, passwords: passwords)
        let uid = getuid()
        let root = try sessionRoot(ownerUID: uid)
        let parent = try openDirectory(root, ownerUID: uid, creating: true)
        let name = UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { Darwin.close(parent); throw failure() }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { unlinkat(parent, name, AT_REMOVEDIR); Darwin.close(parent); throw failure() }
        let secret = UUID().uuidString + UUID().uuidString
        let result = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true), ownerUID: uid, fd: child, parentFD: parent, token: secret)
        do {
            let request = SessionRequest(configuration: configuration, passwords: passwords, parentPID: getpid(), ownerUID: uid, token: secret)
            let data = try JSONEncoder().encode(request)
            guard data.count <= 1_048_576 else { throw AppProxyError(localized: "error.request.size") }
            try result.write(data, named: "request.json")
            try result.heartbeat()
            return result
        } catch { try? result.cleanup(); throw error }
    }

    /// On UI startup, remove old secrets only with positive evidence that no active session owns them.
    /// EPERM and unknown/malformed state are treated as live; this never kills a process.
    @discardableResult public static func cleanupAbandoned() throws -> Int {
        let uid = getuid()
        guard geteuid() == uid else { throw AppProxyError(localized: "error.session.cleanup_unprivileged") }
        let root = try sessionRoot(ownerUID: uid)
        let parent: Int32
        do { parent = try openDirectory(root, ownerUID: uid, creating: false) }
        catch let error as POSIXError where error.code == .ENOENT { return 0 }
        defer { Darwin.close(parent) }
        let duplicate = dup(parent)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else { if duplicate >= 0 { Darwin.close(duplicate) }; throw failure() }
        defer { closedir(directory) }
        var removed = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard UUID(uuidString: name) != nil,
                  let candidate = try? open(url: root.appendingPathComponent(name, isDirectory: true), ownerUID: uid) else { continue }
            do {
                let status = try candidate.readStatus()
                if let corePID = status?.corePID, !processConfirmedGone(corePID) { continue }
                let request = try? candidate.readRequest(consuming: false)
                let deadRequest = request.map { processConfirmedGone($0.parentPID) } ?? false
                let terminalWithoutCore = request == nil && (status?.phase == .stopped || status?.phase == .failed) && status?.corePID == nil
                guard deadRequest || terminalWithoutCore else { continue }
                // A consumed request with an ambiguous starting/running state needs investigation, not deletion.
                try candidate.cleanup(); removed += 1
            } catch { continue }
        }
        return removed
    }
    private static func processConfirmedGone(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    public static func open(url: URL, ownerUID: UInt32) throws -> SessionDirectory {
        let root = try sessionRoot(ownerUID: ownerUID)
        guard url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path,
              url.deletingLastPathComponent().path == root.path,
              UUID(uuidString: url.lastPathComponent) != nil else { throw AppProxyError(localized: "error.session.path") }
        let parent = try openDirectory(root, ownerUID: ownerUID, creating: false)
        let child = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { Darwin.close(parent); throw failure() }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_uid == ownerUID, info.st_mode & 0o777 == 0o700 else {
            Darwin.close(child); Darwin.close(parent); throw AppProxyError(localized: "error.session.permissions")
        }
        return SessionDirectory(url: url, ownerUID: ownerUID, fd: child, parentFD: parent)
    }

    public func readRequest(consuming: Bool) throws -> SessionRequest {
        let data = try read("request.json", maximum: 1_048_576)
        if consuming, unlinkat(fd, "request.json", 0) != 0 { throw Self.failure() }
        // This rejects alternate protocol versions/options; the compiler also only emits allowlisted fields.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["configuration", "passwords", "parentPID", "ownerUID", "token"]) else { throw AppProxyError(localized: "error.request.format") }
        let request: SessionRequest
        do { request = try JSONDecoder().decode(SessionRequest.self, from: data) }
        catch { throw AppProxyError(localized: "error.request.format") }
        guard request.ownerUID == ownerUID, request.parentPID > 1, request.token.count == 72,
              request.passwords.count <= 128,
              request.passwords.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.utf8.count <= 4096 }),
              UUID(uuidString: String(request.token.prefix(36))) != nil,
              UUID(uuidString: String(request.token.suffix(36))) != nil else { throw AppProxyError(localized: "error.request.identity") }
        try request.configuration.validate()
        token = request.token
        return request
    }

    public func heartbeat() throws {
        guard let token else { throw AppProxyError(localized: "error.session.token") }
        try write(JSONEncoder().encode(SessionHeartbeat(token: token, timestamp: Date().timeIntervalSince1970)), named: "heartbeat")
    }
    public func requestStop() throws {
        guard let token else { throw AppProxyError(localized: "error.session.token") }
        try write(Data(token.utf8), named: "stop")
    }
    public func stopReason(token: String, now: Date = Date(), maximumHeartbeatAge: TimeInterval = 10) throws -> SessionStopReason? {
        if let stop = try readIfPresent("stop", maximum: 128), String(data: stop, encoding: .utf8) == token { return .requested }
        guard let data = try readIfPresent("heartbeat", maximum: 512),
              let heartbeat = try? JSONDecoder().decode(SessionHeartbeat.self, from: data), heartbeat.token == token else { return .staleHeartbeat }
        let age = now.timeIntervalSince1970 - heartbeat.timestamp
        return age > maximumHeartbeatAge || age < -2 ? .staleHeartbeat : nil
    }
    public func readStatus() throws -> SessionStatus? {
        guard let data = try readIfPresent("status.json", maximum: 524_288) else { return nil }
        return try JSONDecoder().decode(SessionStatus.self, from: data)
    }
    public func writeStatus(_ status: SessionStatus) throws { try write(JSONEncoder().encode(status), named: "status.json") }

    /// Intended for the unprivileged UI after helper exit. Never follows links or removes nested folders.
    public func cleanup() throws {
        let duplicate = dup(fd)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else { if duplicate >= 0 { Darwin.close(duplicate) }; throw Self.failure() }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw Self.failure() }
        }
        var actual = stat(); var expected = stat()
        if fstatat(parentFD, url.lastPathComponent, &actual, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }; throw Self.failure()
        }
        guard fstat(fd, &expected) == 0, actual.st_ino == expected.st_ino, actual.st_dev == expected.st_dev else { throw AppProxyError(localized: "error.session.replaced") }
        guard unlinkat(parentFD, url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw Self.failure() }
    }

    private func readIfPresent(_ name: String, maximum: Int) throws -> Data? {
        do { return try read(name, maximum: maximum) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    private func read(_ name: String, maximum: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == ownerUID, info.st_mode & 0o777 == 0o600,
              info.st_size >= 0, info.st_size <= maximum else { throw AppProxyError(localized: "error.session.file_metadata") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
            guard data.count + count <= maximum else { throw AppProxyError(localized: "error.session.file_size") }
            data.append(buffer, count: count)
        }
        return data
    }
    private func write(_ data: Data, named name: String) throws {
        let temporary = ".pending-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
                guard count > 0 else { throw AppProxyError(localized: "error.session.file_write") }; offset += count
            }
        }
        guard fchmod(file, 0o600) == 0,
              (geteuid() == ownerUID || fchown(file, ownerUID, gid_t.max) == 0),
              fsync(file) == 0,
              renameat(fd, temporary, fd, name) == 0 else { throw Self.failure() }
    }
    private static func sessionRoot(ownerUID: UInt32) throws -> URL {
        guard let entry = getpwuid(ownerUID), let home = entry.pointee.pw_dir else { throw AppProxyError(localized: "error.session.user") }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Library/Application Support/App Proxy/Sessions", isDirectory: true)
    }
    private static func openDirectory(_ url: URL, ownerUID: UInt32, creating: Bool) throws -> Int32 {
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw failure() }
        do {
            for component in url.pathComponents.dropFirst() {
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, creating {
                    guard mkdirat(current, component, 0o700) == 0 else { throw failure() }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure() }
                var info = stat()
                guard fstat(next, &info) == 0, (info.st_uid == ownerUID || info.st_uid == 0), info.st_mode & 0o022 == 0 else {
                    Darwin.close(next); throw AppProxyError(localized: "error.session.parent_permissions")
                }
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }
    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
