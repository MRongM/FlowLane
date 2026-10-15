import Foundation

/// Launch synchronously on the controller actor so cancellation never races an unstarted Process.
/// Waiting and pipe draining happen outside the UI actor. This has no privileged IPC interface.
final class CommandProcess: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    var isRunning: Bool { process.isRunning }
    init(executable: URL, arguments: [String]) {
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }
    func start() throws { try process.run() }
    func cancel() { if process.isRunning { process.terminate() } }
    func result() async -> (code: Int32, output: String) {
        await Task.detached { [self] in
            var output = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if output.count < 4096 { output.append(chunk.prefix(4096 - output.count)) }
            }
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }.value
    }
}
