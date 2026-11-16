import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandError: LocalizedError {
    case launchFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "无法启动命令：\(m)"
        case .timedOut(let m): return "命令超时：\(m)"
        }
    }
}

/// Runs an executable synchronously. Call from a background thread.
/// Both pipes are drained concurrently so large outputs (screenshots) never deadlock.
public func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice

    do { try process.run() } catch { throw CommandError.launchFailed("\(executable): \(error.localizedDescription)") }

    var out = Data(), err = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = group.wait(timeout: .now() + 2)
        throw CommandError.timedOut(([executable] + arguments).joined(separator: " "))
    }
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
}
