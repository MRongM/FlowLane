import Foundation

public enum RuntimePhase: String, Codable, Sendable { case stopped, starting, running, stopping, failed
    public var title: String {
        switch self { case .stopped: return "未启动"; case .starting: return "启动中"; case .running: return "运行中"; case .stopping: return "停止中"; case .failed: return "失败" }
    }
}
public enum RuntimeEvent { case start, ready, stop, finished, failure(String) }
public struct RuntimeStateMachine {
    public private(set) var phase: RuntimePhase = .stopped
    public private(set) var message: String = "网络未接管"
    public init() {}
    public mutating func apply(_ event: RuntimeEvent) throws {
        switch (phase, event) {
        case (.stopped, .start), (.failed, .start): phase = .starting; message = "等待管理员授权和内核就绪"
        case (.starting, .ready): phase = .running; message = "TUN 已启动；未匹配连接直连"
        case (.starting, .stop), (.running, .stop): phase = .stopping; message = "正在停止并检查网络恢复"
        case (.starting, .finished), (.stopping, .finished), (.running, .finished): phase = .stopped; message = "内核已停止"
        case (_, .failure(let reason)): phase = .failed; message = reason
        default: throw AppProxyError("运行状态转换无效")
        }
    }
}
