import AppKit
import AppProxyKit
import Network
import SwiftUI

@MainActor
final class RuntimeController: ObservableObject {
    @Published private(set) var state = RuntimeStateMachine()
    @Published private(set) var logs: [String] = []
    @Published private(set) var restoration: String?
    @Published private(set) var operationPending = false
    private var session: SessionDirectory?
    private var timer: Timer?
    private var authorizer: CommandProcess?
    private let makeCommand: (URL, [String]) -> CommandProcess
    private let reachability: (ProxyProfile) async throws -> Void
    private var generation = UUID()
    private var stopPending = false
    var active: Bool { operationPending || [.starting, .running, .stopping].contains(state.phase) }
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AppProxyHelper") }

    init(makeCommand: @escaping (URL, [String]) -> CommandProcess = { CommandProcess(executable: $0, arguments: $1) }, reachability: @escaping (ProxyProfile) async throws -> Void = { try await RuntimeController.checkReachability($0) }) {
        self.makeCommand = makeCommand; self.reachability = reachability
    }

    func start(store: AppStore) {
        guard !active, store.loaded else { return }
        do {
            guard store.configuration.rules.contains(where: \.enabled) else { throw AppProxyError("请至少启用一条应用规则") }
            try state.apply(.start); logs = []; restoration = nil; stopPending = false
            operationPending = true
            let s = try SessionDirectory.create(configuration: store.configuration, passwords: store.passwords())
            let configuration = store.configuration
            session = s; generation = UUID(); let current = generation
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
            Task {
                do {
                    let used = Set(configuration.rules.filter(\.enabled).map(\.proxyID))
                    for p in configuration.proxies where used.contains(p.id) {
                        guard !stopPending else { finish(); return }
                        try await reachability(p)
                    }
                    guard current == generation, !stopPending else { finish(); return }
                    let checker = makeCommand(helperURL, ["check", "--session", s.url.path])
                    try checker.start()
                    let check = await checker.result()
                    guard !stopPending else { finish(); return }
                    guard check.code == 0 else { throw AppProxyError("内核配置校验失败。" + check.output) }
                    guard !stopPending else { finish(); return }
                    let command = Self.shellQuote(helperURL.path) + " run --session " + Self.shellQuote(s.url.path) + " --owner \(getuid()) --parent \(getpid())"
                    // Only fixed executable/verbs and an app-generated UUID path enter the shell.
                    let appleScript = "do shell script " + Self.appleScriptQuote(command) + " with administrator privileges"
                    let process = makeCommand(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", appleScript])
                    try process.start(); authorizer = process
                    let result = await process.result()
                    guard current == generation else { return }
                    poll()
                    if stopPending, state.phase != .failed { finish() }
                    else if result.code != 0, state.phase != .failed {
                        let cancelled = result.output.contains("-128") || result.output.localizedCaseInsensitiveContains("canceled")
                        fail(cancelled ? "管理员授权已取消，网络未启动" : "启动失败：管理员授权或监督进程退出。" + String(result.output.prefix(300)))
                    } else if state.phase != .failed { finish() }
                    else { cleanup() }
                } catch {
                    if current == generation {
                        if stopPending, state.phase != .failed { finish() }
                        else { fail(error.localizedDescription) }
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    func stop() {
        guard active else { return }
        let waitingForAuthorization = state.phase == .starting && (try? session?.readStatus()) == nil
        stopPending = true
        try? state.apply(.stop)
        do { try session?.requestStop() } catch { logs.append("写入停止请求失败：" + error.localizedDescription) }
        if waitingForAuthorization { authorizer?.cancel() }
    }
    func poll() {
        guard let session else { return }
        do {
            if !stopPending { try session.heartbeat() }
            if let status = try session.readStatus() {
                logs = status.logs
                restoration = status.restoration
                switch status.phase {
                case .running: if state.phase == .starting { try state.apply(.ready) }
                case .stopping: if state.phase == .running || state.phase == .starting { try state.apply(.stop) }
                case .failed: try state.apply(.failure(status.message))
                case .stopped: if state.phase != .failed && state.phase != .stopped { try state.apply(.finished) }
                case .starting: break
                }
            }
        } catch { logs.append("状态读取失败：" + error.localizedDescription) }
    }
    func shutdown() {
        stop(); timer?.invalidate(); timer = nil
        // No synchronous waiting on the main thread. Helper observes STOP/heartbeat and parent death.
    }
    private func finish() {
        if state.phase != .stopped { try? state.apply(.finished) }
        cleanup()
    }
    private func fail(_ message: String) {
        try? state.apply(.failure(message)); cleanup()
    }
    private func cleanup() {
        timer?.invalidate(); timer = nil
        try? session?.cleanup(); session = nil; authorizer = nil; operationPending = false
    }
    nonisolated private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    nonisolated private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    nonisolated private static func checkReachability(_ profile: ProxyProfile) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: NWEndpoint.Port(rawValue: UInt16(profile.port))!, using: .tcp)
            let queue = DispatchQueue(label: "app-proxy.preflight")
            var completed = false
            let complete: (Error?) -> Void = { error in
                guard !completed else { return }; completed = true
                connection.stateUpdateHandler = nil; connection.cancel()
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: complete(nil)
                case .failed: complete(AppProxyError("上游不可达：\(profile.name)（\(profile.host):\(profile.port)）。请检查代理服务。"))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { complete(AppProxyError("上游连接超时：" + profile.name)) }
        }
    }
}
