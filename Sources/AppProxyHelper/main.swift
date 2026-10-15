import Foundation
import Darwin
import CryptoKit
import AppProxyKit

private let pinnedCoreSHA256 = "28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2"
private struct Arguments {
    let checking: Bool
    let sessionURL: URL
    let owner: UInt32
    let parent: Int32?
    init(_ arguments: [String]) throws {
        guard let command = arguments.first, ["check", "run"].contains(command) else { throw AppProxyError("用法：AppProxyHelper check --session ABS 或 run --session ABS --owner UID --parent PID") }
        checking = command == "check"
        guard arguments.count == (checking ? 3 : 7), arguments[1] == "--session", arguments[2].hasPrefix("/") else { throw AppProxyError("helper 参数无效") }
        sessionURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if checking { owner = getuid(); parent = nil }
        else {
            guard arguments[3] == "--owner", arguments[5] == "--parent",
                  let uid = UInt32(arguments[4]), uid > 0, let pid = Int32(arguments[6]), pid > 1 else { throw AppProxyError("helper 身份参数无效") }
            owner = uid; parent = pid
        }
        guard sessionURL.path == arguments[2] else { throw AppProxyError("helper 会话路径必须是绝对标准路径") }
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
    guard let pointer = mkdtemp(&name) else { throw AppProxyError("无法建立私有运行目录") }
    let path = String(cString: pointer)
    guard chmod(path, 0o700) == 0 else { rmdir(path); throw AppProxyError("无法设置运行目录权限") }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func fixedCoreURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { throw AppProxyError("无法定位捆绑内核") }
    let helper = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    guard helper.lastPathComponent == "AppProxyHelper", helper.deletingLastPathComponent().lastPathComponent == "MacOS" else { throw AppProxyError("请使用完整 App Proxy.app 中的 helper") }
    return helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/sing-box")
}

private func stageCore(at directory: URL) throws -> URL {
    let source = try fixedCoreURL()
    let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw AppProxyError("缺少固定版本的捆绑内核") }
    defer { Darwin.close(input) }
    var info = stat()
    guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size < 200_000_000 else { throw AppProxyError("捆绑内核类型或大小无效") }
    let destination = directory.appendingPathComponent("sing-box")
    let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
    guard output >= 0 else { throw AppProxyError("无法复制内核至私有目录") }
    defer { Darwin.close(output) }
    var buffer = [UInt8](repeating: 0, count: 65_536); var total = 0
    while true {
        let count = Darwin.read(input, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 { if errno == EINTR { continue }; throw AppProxyError("读取内核失败") }
        total += count; guard total <= 200_000_000 else { throw AppProxyError("内核超过大小限制") }
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < count {
                let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                if written < 0 { if errno == EINTR { continue }; throw AppProxyError("复制内核失败") }
                guard written > 0 else { throw AppProxyError("复制内核失败") }; offset += written
            }
        }
    }
    guard fsync(output) == 0, fchmod(output, 0o700) == 0 else { throw AppProxyError("内核复制未完成") }
    // Hash the destination, not the user-controlled source: protects replacement during copy.
    let copied = try Data(contentsOf: destination, options: .mappedIfSafe)
    let hash = SHA256.hash(data: copied).map { String(format: "%02x", $0) }.joined()
    guard hash == pinnedCoreSHA256 else { throw AppProxyError("内核 SHA-256 校验失败，请重新构建应用") }
    return destination
}

private func writeConfiguration(_ data: Data, at url: URL) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw AppProxyError("无法写入私有配置") }
    defer { Darwin.close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 { if errno == EINTR { continue }; throw AppProxyError("写入私有配置失败") }
            guard count > 0 else { throw AppProxyError("写入私有配置失败") }; offset += count
        }
    }
    guard fsync(fd) == 0 else { throw AppProxyError("写入私有配置失败") }
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
    if cancellation.cancelled { terminate(process); throw AppProxyError("会话已取消；网络未启动") }
    guard !process.isRunning else { terminate(process); throw AppProxyError("内核配置校验超时") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AppProxyError("内核配置校验失败；请检查代理与应用规则") }
}

private func runSession(_ arguments: Arguments, session: SessionDirectory, request: SessionRequest, core: URL, configuration: URL, localUpstream: LocalUpstreamPlan, cancellation: Cancellation) throws {
    try localUpstream.validateOwners()
    guard parentBelongsToOwner(request.parentPID, owner: request.ownerUID), try session.stopReason(token: request.token) == nil else { throw AppProxyError("启动已取消或界面会话已失效") }
    let before = NetworkSnapshot.capture()
    let process = coreProcess(core: core, configuration: configuration, command: "run")
    let bundleNotices = localUpstream.bundlePaths.map { "本地上游整个应用优先直连（覆盖应用规则）：" + $0 }
    let exactNotices = localUpstream.processPaths.filter { LocalUpstream.enclosingBundle(executablePath: $0) == nil }.map { "本地上游进程优先直连（覆盖应用规则）：" + $0 }
    let output = CoreOutput(request: request, notices: bundleNotices + exactNotices); let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty { output.append(data) }
        else { handle.readabilityHandler = nil }
    }
    var activated = false
    var failure: String?
    var reason = "已收到停止请求"
    defer { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
    try session.writeStatus(SessionStatus(phase: .starting, message: "内核校验通过，正在建立 TUN", logs: output.snapshot().logs))
    // Recheck after read-only snapshot/config checks: STOP during authorization cannot activate networking.
    guard !cancellation.cancelled, parentBelongsToOwner(request.parentPID, owner: request.ownerUID), try session.stopReason(token: request.token) == nil else { throw AppProxyError("启动已取消或界面会话已失效") }
    try localUpstream.validateOwners()
    do {
        try process.run(); activated = true
        let started = Date(); var reportedRunning = false
        while process.isRunning {
            let state = output.snapshot()
            if cancellation.cancelled { reason = "helper 收到退出信号"; break }
            try localUpstream.validateOwners()
            if !parentBelongsToOwner(request.parentPID, owner: request.ownerUID) { reason = "界面进程已退出"; break }
            if let stop = try session.stopReason(token: request.token) { reason = stop == .requested ? "已收到停止请求" : "界面心跳已失效"; break }
            if !reportedRunning && !state.ready && Date().timeIntervalSince(started) > 20 { failure = "内核在 20 秒内未报告就绪"; break }
            if state.ready { reportedRunning = true }
            try session.writeStatus(SessionStatus(phase: reportedRunning ? .running : .starting, message: reportedRunning ? "TUN 已启动；未匹配流量直连，已匹配 UDP 拒绝" : "等待内核启动就绪", corePID: process.processIdentifier, logs: state.logs))
            Thread.sleep(forTimeInterval: 0.35)
        }
        if !process.isRunning && failure == nil { process.waitUntilExit(); failure = "内核意外退出（状态 \(process.terminationStatus)）" }
    } catch { failure = (error as? AppProxyError)?.message ?? "运行会话通信失败；已停止内核" }
    guard activated else { throw AppProxyError("无法启动固定内核；未启用网络接管") }
    if activated {
        try? session.writeStatus(SessionStatus(phase: .stopping, message: failure ?? reason, corePID: process.isRunning ? process.processIdentifier : nil, logs: output.snapshot().logs))
        terminate(process)
        // Closing utun removes its routes asynchronously. Observe boundedly, never replay old routing state.
        var after = NetworkSnapshot.capture()
        for _ in 0..<3 where !before.matches(after) { Thread.sleep(forTimeInterval: 0.4); after = NetworkSnapshot.capture() }
        let restoration = before.comparison(to: after)
        let clean = before.matches(after)
        try session.writeStatus(SessionStatus(phase: failure != nil || !clean ? .failed : .stopped, message: failure ?? (clean ? "内核已停止，网络状态已核验" : "内核已停止，请检查网络恢复差异"), logs: output.snapshot().logs, restoration: restoration))
        if failure != nil || !clean { throw AppProxyError("会话已停止；请查看状态中的恢复检查结果") }
    }
}

private func main() -> Int32 {
    let cancellation = Cancellation()
    let signalSources = installSignalHandlers(cancellation)
    defer { signalSources.forEach { $0.cancel() } }
    var session: SessionDirectory?
    do {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        guard arguments.checking || geteuid() == 0 else { throw AppProxyError("run 需要显式的管理员授权") }
        let opened = try SessionDirectory.open(url: arguments.sessionURL, ownerUID: arguments.owner); session = opened
        let request = try opened.readRequest(consuming: !arguments.checking)
        guard arguments.parent == nil || arguments.parent == request.parentPID,
              parentBelongsToOwner(request.parentPID, owner: request.ownerUID) else { throw AppProxyError("会话父进程或所有者无效") }
        if !arguments.checking {
            guard try opened.stopReason(token: request.token) == nil else { throw AppProxyError("启动已取消或界面心跳已失效") }
            try opened.writeStatus(SessionStatus(phase: .starting, message: "已获管理员授权，正在校验内核"))
        }
        let stage = try privateStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let core = try stageCore(at: stage)
        let localUpstream: LocalUpstreamPlan
        if arguments.checking { localUpstream = .empty }
        else {
            localUpstream = try LocalUpstream.resolve(configuration: request.configuration) {
                guard !cancellation.cancelled, parentBelongsToOwner(request.parentPID, owner: request.ownerUID), try opened.stopReason(token: request.token) == nil else { throw AppProxyError("会话已取消或界面已退出；网络未启动") }
            }
        }
        guard !cancellation.cancelled else { throw AppProxyError("会话已取消；网络未启动") }
        let config = stage.appendingPathComponent("config.json")
        let compiled: Data
        do { compiled = try ConfigurationCompiler.compile(request.configuration, passwords: request.passwords, corePath: core.path, directProcessPaths: localUpstream.processPaths, directBundlePaths: localUpstream.bundlePaths) }
        catch { throw AppProxyError("代理配置或所需密码无效") }
        try writeConfiguration(compiled, at: config)
        try checkCore(core, configuration: config, cancellation: cancellation)
        if arguments.checking { print("固定内核配置校验通过；未启用网络接管"); return 0 }
        try runSession(arguments, session: opened, request: request, core: core, configuration: config, localUpstream: localUpstream, cancellation: cancellation)
        return 0
    } catch {
        // Only fixed helper messages are returned; Foundation/process errors may contain paths/arguments.
        let message = (error as? AppProxyError)?.message ?? "helper 安全校验或会话操作失败"
        if let session {
            let previous = try? session.readStatus()
            if previous?.restoration == nil { try? session.writeStatus(SessionStatus(phase: .failed, message: message, logs: previous?.logs ?? [])) }
        }
        FileHandle.standardError.write(Data((message + "\n").utf8)); return 1
    }
}
exit(main())
