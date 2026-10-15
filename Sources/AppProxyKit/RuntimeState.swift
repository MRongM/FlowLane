import Foundation

public enum RuntimePhase: String, Codable, Sendable {
    case stopped, starting, running, stopping, failed
    public var title: String { Localization.text("phase." + rawValue, language: .en, table: .interface) }
}
public enum RuntimeEvent { case start, ready, stop, finished, failure(String), failureMessage(LocalizedMessage) }
public struct RuntimeStateMachine {
    public private(set) var phase: RuntimePhase = .stopped
    public private(set) var content = LocalizedMessage("state.idle")
    public var message: String { content.rendered(in: .en) }
    public init() {}
    public mutating func apply(_ event: RuntimeEvent) throws {
        switch (phase, event) {
        case (.stopped, .start), (.failed, .start): phase = .starting; content = LocalizedMessage("state.starting")
        case (.starting, .ready): phase = .running; content = LocalizedMessage("state.running")
        case (.starting, .stop), (.running, .stop): phase = .stopping; content = LocalizedMessage("state.stopping")
        case (.starting, .finished), (.stopping, .finished), (.running, .finished): phase = .stopped; content = LocalizedMessage("state.stopped")
        case (_, .failure(let reason)): phase = .failed; content = .verbatim(reason)
        case (_, .failureMessage(let reason)): phase = .failed; content = reason
        default: throw AppProxyError(localized: "error.state.transition")
        }
    }
}
