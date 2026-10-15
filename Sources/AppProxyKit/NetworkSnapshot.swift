import Foundation
import Darwin

/// Read-only evidence. Differences can come from other software and are never restored blindly.
public struct NetworkSnapshot: Sendable {
    public let values: [String: String]
    public init(values: [String: String]) { self.values = values }
    public static func capture() -> NetworkSnapshot {
        let commands: [(String, String, [String])] = [
            ("routes.ipv4", "/usr/sbin/netstat", ["-rn", "-f", "inet"]),
            ("routes.ipv6", "/usr/sbin/netstat", ["-rn", "-f", "inet6"]),
            ("dns", "/usr/sbin/scutil", ["--dns"]),
            ("system.proxy", "/usr/sbin/scutil", ["--proxy"])
        ]
        var result: [String: String] = [:]
        for (name, executable, arguments) in commands {
            let captured = captureCommand(executable, arguments: arguments)
            result[name] = (name == "routes.ipv4" || name == "routes.ipv6") && captured != "<unavailable>" ? normalizeRoutes(captured) : captured
        }
        return NetworkSnapshot(values: result)
    }
    public static func normalizeRoutes(_ text: String) -> String {
        text.split(separator: "\n").compactMap { line -> String? in
            let columns = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard columns.count >= 4, columns[0] != "Destination", columns[0] != "Routing", !columns[2].contains("L") else { return nil }
            return columns.prefix(4).joined(separator: " ")
        }.sorted().joined(separator: "\n")
    }
    private static func captureCommand(_ executable: String, arguments: [String]) -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let capture = SnapshotCommandOutput(); let finished = DispatchSemaphore(value: 0)
        do { try process.run() } catch { return "<unavailable>" }
        DispatchQueue.global().async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }; capture.append(data)
            }
            finished.signal()
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
        guard finished.wait(timeout: .now() + 1) == .success, !timedOut, process.terminationStatus == 0 else { return "<unavailable>" }
        return capture.result()
    }
    public func comparison(to after: NetworkSnapshot) -> String { comparisonContent(to: after).rendered(in: .en) }
    public func comparisonContent(to after: NetworkSnapshot) -> LocalizedMessage {
        let names = Set(values.keys).union(after.values.keys).sorted()
        let unavailable = names.filter { values[$0] == nil || after.values[$0] == nil || values[$0] == "<unavailable>" || after.values[$0] == "<unavailable>" }
        let changed = names.filter { values[$0] != after.values[$0] && !unavailable.contains($0) }
        func category(_ name: String) -> LocalizedMessage {
            switch name {
            case "routes.ipv4": return LocalizedMessage("snapshot.category.ipv4")
            case "routes.ipv6": return LocalizedMessage("snapshot.category.ipv6")
            case "dns": return LocalizedMessage("snapshot.category.dns")
            case "system.proxy": return LocalizedMessage("snapshot.category.proxy")
            default: return .verbatim(name)
            }
        }
        func list(_ identifiers: [String]) -> LocalizedMessage {
            identifiers.map(category).reduce(nil as LocalizedMessage?) { partial, next in
                partial.map { LocalizedMessage("snapshot.list", values: [$0, next]) } ?? next
            } ?? .verbatim("")
        }
        if !unavailable.isEmpty {
            return changed.isEmpty ? LocalizedMessage("snapshot.incomplete", values: [list(unavailable)]) : LocalizedMessage("snapshot.incomplete.changed", values: [list(unavailable), list(changed)])
        }
        return changed.isEmpty ? LocalizedMessage("snapshot.unchanged") : LocalizedMessage("snapshot.changed", values: [list(changed)])
    }
    public func matches(_ after: NetworkSnapshot) -> Bool {
        values == after.values && !values.values.contains("<unavailable>")
    }
}

private final class SnapshotCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var oversized = false
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > 2_097_152 { oversized = true }
        else { data.append(chunk) }
    }
    func result() -> String {
        lock.lock(); defer { lock.unlock() }
        return oversized ? "<unavailable>" : String(decoding: data, as: UTF8.self)
    }
}
