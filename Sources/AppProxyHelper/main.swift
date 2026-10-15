import Foundation
import Darwin
import CryptoKit
import AppProxyKit

#if arch(arm64)
private let pinnedCoreSHA256 = "28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2"
#elseif arch(x86_64)
private let pinnedCoreSHA256 = "4d63d13fe7516a5d0a76c764095238f9d51ada7bfa5d18cf5030ca3032882c68"
#else
#error("Unsupported architecture: build for arm64 or x86_64")
#endif
private struct Arguments {
    let checking: Bool
    let sessionURL: URL
    let owner: UInt32
    let parent: Int32?
    init(_ arguments: [String]) throws {
        guard let command = arguments.first, ["check", "run"].contains(command) else { throw AppProxyError(localized: "helper.usage") }
        checking = command == "check"
        guard arguments.count == (checking ? 3 : 7), arguments[1] == "--session", arguments[2].hasPrefix("/") else { throw AppProxyError(localized: "helper.arguments") }
        sessionURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if checking { owner = getuid(); parent = nil }
        else {
            guard arguments[3] == "--owner", arguments[5] == "--parent",
                  let uid = UInt32(arguments[4]), uid > 0, let pid = Int32(arguments[6]), pid > 1 else { throw AppProxyError(localized: "helper.identity_arguments") }
            owner = uid; parent = pid
        }
        guard sessionURL.path == arguments[2] else { throw AppProxyError(localized: "helper.absolute_path") }
    }
}

private final class CoreOutput {
    private let lock = NSLock()
    private var pending = Data()
    private var droppingLongLine = false
    private var lines: [String] = []
    private var isReady = false
    private let request: SessionRequest
    init(request: SessionRequest, notices: [String] = []) {
        self.request = request
        self.lines = notices.map { LogSanitizer.redact($0, configuration: request.configuration, passwords: Array(request.passwords.values)) }
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        for byte in data {
            if byte == 10 {
                if !droppingLongLine, !pending.isEmpty {
                    let raw = String(decoding: pending, as: UTF8.self)
                    if raw.contains("sing-box started") { isReady = true }
                    let clean = raw.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                    let line = LogSanitizer.redact(clean, configuration: request.configuration, passwords: Array(request.passwords.values))
                        .unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined()
                    lines.append(line)
                    if lines.count > 150 { lines.removeFirst(lines.count - 150) }
                }
                pending.removeAll(keepingCapacity: true); droppingLongLine = false
            } else if pending.count < 16_384 && !droppingLongLine { pending.append(byte) }
            else { pending.removeAll(keepingCapacity: true); droppingLongLine = true }
        }
    }
    func snapshot() -> (ready: Bool, logs: [String]) { lock.lock(); defer { lock.unlock() }; return (isReady, lines) }
}

private final class Cancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

private func installSignalHandlers(_ cancellation: Cancellation) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT, SIGHUP, SIGQUIT].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { cancellation.cancel() }; source.resume(); return source
    }
}

private func parentBelongsToOwner(_ pid: Int32, owner: UInt32) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    return sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 && size > 0 && info.kp_eproc.e_ucred.cr_uid == owner && info.kp_proc.p_pid == pid
}

private func privateStage() throws -> URL {
    var name = Array("/private/tmp/app-proxy-runtime.XXXXXX".utf8CString)
    // mkdtemp returns a pointer into this array. Decode the path before the
    // buffer borrow ends so optimized builds cannot release its storage early.
    let path = try name.withUnsafeMutableBufferPointer { buffer -> String in
        guard let base = buffer.baseAddress, let pointer = mkdtemp(base) else {
            throw AppProxyError(localized: "helper.stage.create")
        }
        return String(cString: pointer)
    }
    guard chmod(path, 0o700) == 0 else { rmdir(path); throw AppProxyError(localized: "helper.stage.permissions") }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func fixedCoreURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { throw AppProxyError(localized: "helper.core.locate") }
    let helper = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    guard helper.lastPathComponent == "AppProxyHelper", helper.deletingLastPathComponent().lastPathComponent == "MacOS" else { throw AppProxyError(localized: "helper.core.bundle") }
    return helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/sing-box")
}

private func stageCore(at directory: URL) throws -> URL {
    let source = try fixedCoreURL()
    let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw AppProxyError(localized: "helper.core.missing") }
    defer { Darwin.close(input) }
    var info = stat()
    guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size < 200_000_000 else { throw AppProxyError(localized: "helper.core.metadata") }
    let destination = directory.appendingPathComponent("sing-box")
    let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
    guard output >= 0 else { throw AppProxyError(localized: "helper.core.copy") }
    defer { Darwin.close(output) }
    var buffer = [UInt8](repeating: 0, count: 65_536); var total = 0
    while true {
        let count = Darwin.read(input, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 { if errno == EINTR { continue }; throw AppProxyError(localized: "helper.core.read") }
        total += count; guard total <= 200_000_000 else { throw AppProxyError(localized: "helper.core.size") }
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < count {
                let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                if written < 0 { if errno == EINTR { continue }; throw AppProxyError(localized: "helper.core.copy_failed") }
                guard written > 0 else { throw AppProxyError(localized: "helper.core.copy_failed") }; offset += written
            }
        }
    }
    guard fsync(output) == 0, fchmod(output, 0o700) == 0 else { throw AppProxyError(localized: "helper.core.copy_incomplete") }
    // Hash the destination, not the user-controlled source: protects replacement during copy.
    let copied = try Data(contentsOf: destination, options: .mappedIfSafe)
    let hash = SHA256.hash(data: copied).map { String(format: "%02x", $0) }.joined()
    guard hash == pinnedCoreSHA256 else { throw AppProxyError(localized: "helper.core.hash") }
    return destination
}

private func writeConfiguration(_ data: Data, at url: URL) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw AppProxyError(localized: "helper.config.create") }
    defer { Darwin.close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 { if errno == EINTR { continue }; throw AppProxyError(localized: "helper.config.write") }
            guard count > 0 else { throw AppProxyError(localized: "helper.config.write") }; offset += count
        }
    }
    guard fsync(fd) == 0 else { throw AppProxyError(localized: "helper.config.write") }
}

private func coreProcess(core: URL, configuration: URL, command: String) -> Process {
    let process = Process(); process.executableURL = core; process.arguments = [command, "-c", configuration.path]
    process.currentDirectoryURL = configuration.deletingLastPathComponent()
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": configuration.deletingLastPathComponent().path, "TMPDIR": configuration.deletingLastPathComponent().path, "LC_ALL": "C", "NO_COLOR": "1"]
    process.standardInput = FileHandle.nullDevice
    return process
}

private func terminate(_ process: Process) {
    guard process.isRunning else { process.waitUntilExit(); return }
    process.terminate()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

private func checkCore(_ core: URL, configuration: URL, cancellation: Cancellation) throws {
    let process = coreProcess(core: core, configuration: configuration, command: "check")
    // Config-check diagnostics can quote credential-bearing fields; never expose them.
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning && Date() < deadline && !cancellation.cancelled { Thread.sleep(forTimeInterval: 0.05) }
    if cancellation.cancelled { terminate(process); throw AppProxyError(localized: "helper.cancelled") }
    guard !process.isRunning else { terminate(process); throw AppProxyError(localized: "helper.check.timeout") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AppProxyError(localized: "helper.check.failed") }
}

private func runSession(_ arguments: Arguments, session: SessionDirectory, request: SessionRequest, core: URL, configuration: URL, localUpstream: LocalUpstreamPlan, cancellation: Cancellation) throws {
    try localUpstream.validateOwners()
    guard parentBelongsToOwner(request.parentPID, owner: request.ownerUID), try session.stopReason(token: request.token) == nil else { throw AppProxyError(localized: "helper.session.invalid") }
    let before = NetworkSnapshot.capture()
    let process = coreProcess(core: core, configuration: configuration, command: "run")
    let bundleNotices = localUpstream.bundlePaths.map { LocalizedMessage("helper.notice.bundle", arguments: [$0]).rendered(in: .en) }
    let exactNotices = localUpstream.processPaths.filter { LocalUpstream.enclosingBundle(executablePath: $0) == nil }.map { LocalizedMessage("helper.notice.process", arguments: [$0]).rendered(in: .en) }
    let output = CoreOutput(request: request, notices: bundleNotices + exactNotices); let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty { output.append(data) }
        else { handle.readabilityHandler = nil }
    }
    var activated = false
    var failure: LocalizedMessage?
    var reason = LocalizedMessage("helper.stop.requested")
    defer { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
    try session.writeStatus(SessionStatus(phase: .starting, content: LocalizedMessage("helper.tun.creating"), logs: output.snapshot().logs))
    // Recheck after read-only snapshot/config checks: STOP during authorization cannot activate networking.
    guard !cancellation.cancelled, parentBelongsToOwner(request.parentPID, owner: request.ownerUID), try session.stopReason(token: request.token) == nil else { throw AppProxyError(localized: "helper.session.invalid") }
    try localUpstream.validateOwners()
    do {
        try process.run(); activated = true
        let started = Date(); var reportedRunning = false
        while process.isRunning {
            let state = output.snapshot()
            if cancellation.cancelled { reason = LocalizedMessage("helper.stop.signal"); break }
            try localUpstream.validateOwners()
            if !parentBelongsToOwner(request.parentPID, owner: request.ownerUID) { reason = LocalizedMessage("helper.stop.parent"); break }
            if let stop = try session.stopReason(token: request.token) { reason = LocalizedMessage(stop == .requested ? "helper.stop.requested" : "helper.stop.heartbeat"); break }
            if !reportedRunning && !state.ready && Date().timeIntervalSince(started) > 20 { failure = LocalizedMessage("helper.core.not_ready"); break }
            if state.ready { reportedRunning = true }
            try session.writeStatus(SessionStatus(phase: reportedRunning ? .running : .starting, content: LocalizedMessage(reportedRunning ? "helper.tun.running" : "helper.core.waiting"), corePID: process.processIdentifier, logs: state.logs))
            Thread.sleep(forTimeInterval: 0.35)
        }
        if !process.isRunning && failure == nil { process.waitUntilExit(); failure = LocalizedMessage("helper.core.exited", arguments: [String(process.terminationStatus)]) }
    } catch { failure = (error as? AppProxyError)?.content ?? LocalizedMessage("helper.communication") }
    guard activated else { throw AppProxyError(localized: "helper.core.start_failed") }
    if activated {
        try? session.writeStatus(SessionStatus(phase: .stopping, content: failure ?? reason, corePID: process.isRunning ? process.processIdentifier : nil, logs: output.snapshot().logs))
        terminate(process)
        // Closing utun removes its routes asynchronously. Observe boundedly, never replay old routing state.
        var after = NetworkSnapshot.capture()
        for _ in 0..<3 where !before.matches(after) { Thread.sleep(forTimeInterval: 0.4); after = NetworkSnapshot.capture() }
        let restoration = before.comparisonContent(to: after)
        let clean = before.matches(after)
        try session.writeStatus(SessionStatus(phase: failure != nil || !clean ? .failed : .stopped, content: failure ?? LocalizedMessage(clean ? "helper.stopped.verified" : "helper.stopped.differences"), logs: output.snapshot().logs, restorationContent: restoration))
        if failure != nil || !clean { throw AppProxyError(localized: "helper.stopped.review") }
    }
}

private func main() -> Int32 {
    let cancellation = Cancellation()
    let signalSources = installSignalHandlers(cancellation)
    defer { signalSources.forEach { $0.cancel() } }
    var session: SessionDirectory?
    do {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        guard arguments.checking || geteuid() == 0 else { throw AppProxyError(localized: "helper.authorization") }
        let opened = try SessionDirectory.open(url: arguments.sessionURL, ownerUID: arguments.owner); session = opened
        let request = try opened.readRequest(consuming: !arguments.checking)
        guard arguments.parent == nil || arguments.parent == request.parentPID,
              parentBelongsToOwner(request.parentPID, owner: request.ownerUID) else { throw AppProxyError(localized: "helper.parent") }
        if !arguments.checking {
            guard try opened.stopReason(token: request.token) == nil else { throw AppProxyError(localized: "helper.session.stale") }
            try opened.writeStatus(SessionStatus(phase: .starting, content: LocalizedMessage("helper.authorized")))
        }
        let stage = try privateStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let core = try stageCore(at: stage)
        let localUpstream: LocalUpstreamPlan
        if arguments.checking { localUpstream = .empty }
        else {
            localUpstream = try LocalUpstream.resolve(configuration: request.configuration) {
                guard !cancellation.cancelled, parentBelongsToOwner(request.parentPID, owner: request.ownerUID), try opened.stopReason(token: request.token) == nil else { throw AppProxyError(localized: "helper.session.cancelled") }
            }
        }
        guard !cancellation.cancelled else { throw AppProxyError(localized: "helper.cancelled") }
        let config = stage.appendingPathComponent("config.json")
        let compiled: Data
        do { compiled = try ConfigurationCompiler.compile(request.configuration, passwords: request.passwords, corePath: core.path, directProcessPaths: localUpstream.processPaths, directBundlePaths: localUpstream.bundlePaths) }
        catch { throw AppProxyError(localized: "helper.config.invalid") }
        try writeConfiguration(compiled, at: config)
        try checkCore(core, configuration: config, cancellation: cancellation)
        if arguments.checking { print(LocalizedMessage("helper.check.passed").rendered(in: .en)); return 0 }
        try runSession(arguments, session: opened, request: request, core: core, configuration: config, localUpstream: localUpstream, cancellation: cancellation)
        return 0
    } catch {
        // Only fixed helper messages are returned; Foundation/process errors may contain paths/arguments.
        let content = (error as? AppProxyError)?.content ?? LocalizedMessage("helper.failed")
        if let session {
            let previous = try? session.readStatus()
            if previous?.restoration == nil { try? session.writeStatus(SessionStatus(phase: .failed, content: content, logs: previous?.logs ?? [])) }
        }
        FileHandle.standardError.write(Data((content.rendered(in: .en) + "\n").utf8)); return 1
    }
}
exit(main())
