import Foundation
import Darwin

/// Read-only evidence. Differences can come from other software and are never restored blindly.
public struct NetworkSnapshot: Sendable {
    public let values: [String: String]
    public init(values: [String: String]) { self.values = values }
    public static func capture() -> NetworkSnapshot {
        let commands: [(String, String, [String])] = [
            ("IPv4 路由", "/usr/sbin/netstat", ["-rn", "-f", "inet"]),
            ("IPv6 路由", "/usr/sbin/netstat", ["-rn", "-f", "inet6"]),
            ("DNS", "/usr/sbin/scutil", ["--dns"]),
            ("系统代理", "/usr/sbin/scutil", ["--proxy"])
        ]
        var result: [String: String] = [:]
        for (name, executable, arguments) in commands {
            let captured = captureCommand(executable, arguments: arguments)
            result[name] = name.contains("路由") && captured != "<unavailable>" ? normalizeRoutes(captured) : captured
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
    public func comparison(to after: NetworkSnapshot) -> String {
        let names = Set(values.keys).union(after.values.keys).sorted()
        let unavailable = names.filter { values[$0] == nil || after.values[$0] == nil || values[$0] == "<unavailable>" || after.values[$0] == "<unavailable>" }
        let changed = names.filter { values[$0] != after.values[$0] && !unavailable.contains($0) }
        if !unavailable.isEmpty { return "恢复检查不完整：" + unavailable.joined(separator: "、") + (changed.isEmpty ? "" : "；存在差异：" + changed.joined(separator: "、")) }
        return changed.isEmpty ? "已比较路由、DNS 和系统代理，未发现差异" : "停止后存在差异：" + changed.joined(separator: "、") + "；可能来自其他网络软件，请检查，未覆盖系统配置"
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
