import AppKit
import AppProxyKit
import Network
import SwiftUI

@MainActor
final class RuntimeController: ObservableObject {
    @Published private(set) var state = RuntimeStateMachine()
    @Published private(set) var logs: [String] = []
    @Published private(set) var restoration: LocalizedMessage?
    @Published private(set) var notices: [LocalizedMessage] = []
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
            guard store.configuration.rules.contains(where: \.enabled) else { throw AppProxyError(content: LocalizedMessage("error.enable_rule", table: .interface)) }
            try state.apply(.start); logs = []; notices = []; restoration = nil; stopPending = false
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
                    guard check.code == 0 else {
                        let detail = (try? s.readStatus())?.messageContent ?? .verbatim(check.output)
                        throw AppProxyError(content: LocalizedMessage("error.config_check", values: [detail], table: .interface))
                    }
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
                        fail(cancelled ? LocalizedMessage("error.authorization_cancelled", table: .interface) : LocalizedMessage("error.start_failed", arguments: [String(result.output.prefix(300))], table: .interface))
                    } else if state.phase != .failed { finish() }
                    else { cleanup() }
                } catch {
                    if current == generation {
                        if stopPending, state.phase != .failed { finish() }
                        else { fail(.from(error)) }
                    }
                }
            }
        } catch { fail(.from(error)) }
    }
    func stop() {
        guard active else { return }
        let waitingForAuthorization = state.phase == .starting && (try? session?.readStatus()) == nil
        stopPending = true
        try? state.apply(.stop)
        do { try session?.requestStop() } catch { addNotice(LocalizedMessage("error.stop_request", values: [.from(error)], table: .interface)) }
        if waitingForAuthorization { authorizer?.cancel() }
    }
    func poll() {
        guard let session else { return }
        do {
            if !stopPending { try session.heartbeat() }
            if let status = try session.readStatus() {
                logs = status.logs
                restoration = status.restorationContent ?? status.restoration.map(LocalizedMessage.verbatim)
                switch status.phase {
                case .running: if state.phase == .starting { try state.apply(.ready) }
                case .stopping: if state.phase == .running || state.phase == .starting { try state.apply(.stop) }
                case .failed: try state.apply(.failureMessage(status.messageContent ?? .verbatim(status.message)))
                case .stopped: if state.phase != .failed && state.phase != .stopped { try state.apply(.finished) }
                case .starting: break
                }
            }
        } catch { addNotice(LocalizedMessage("error.status_read", values: [.from(error)], table: .interface)) }
    }
    func shutdown() {
        stop(); timer?.invalidate(); timer = nil
        // No synchronous waiting on the main thread. Helper observes STOP/heartbeat and parent death.
    }
    private func finish() {
        if state.phase != .stopped { try? state.apply(.finished) }
        cleanup()
    }
    private func fail(_ message: LocalizedMessage) {
        try? state.apply(.failureMessage(message)); cleanup()
    }
    private func addNotice(_ message: LocalizedMessage) {
        notices.append(message)
        if notices.count > 50 { notices.removeFirst(notices.count - 50) }
    }
    func displayLogs(language: AppLanguage) -> [String] {
        Array((logs + notices.map { $0.rendered(in: language) }).suffix(150))
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
                case .failed: complete(AppProxyError(content: LocalizedMessage("error.upstream_unreachable", arguments: [profile.name, profile.host, String(profile.port)], table: .interface)))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { complete(AppProxyError(content: LocalizedMessage("error.upstream_timeout", arguments: [profile.name], table: .interface))) }
        }
    }
}
