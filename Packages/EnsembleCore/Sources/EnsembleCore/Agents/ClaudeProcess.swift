import Darwin
import Foundation

public enum ProcessOutput: Sendable, Equatable {
    case line(String)
    case exited(code: Int32, standardError: String)
}

public protocol AgentProcessHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    func send(line: String) throws
    func closeInput()
    func terminate()
    func kill()
}

public protocol AgentProcessLauncher: Sendable {
    func launch(_ launch: ClaudeLaunch) throws -> (AgentProcessHandle, AsyncStream<ProcessOutput>)
}

public struct ClaudeProcessLauncher: AgentProcessLauncher {
    public init() {}

    public func launch(_ launch: ClaudeLaunch) throws -> (AgentProcessHandle, AsyncStream<ProcessOutput>) {
        let process = ClaudeProcess()
        return (process, try process.start(launch))
    }
}

public final class ClaudeProcess: AgentProcessHandle, @unchecked Sendable {
    private static let ignoreBrokenPipes: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var inputClosed = false

    public init() {
        Self.ignoreBrokenPipes
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public var isRunning: Bool { process.isRunning }

    func start(_ launch: ClaudeLaunch) throws -> AsyncStream<ProcessOutput> {
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.worktree
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        try process.run()

        return AsyncStream { continuation in
            let reader = Task.detached {
                async let errorText = Self.readAll(errors.fileHandleForReading)
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        continuation.yield(.line(line))
                    }
                } catch {}
                var code: Int32 = -1
                for await status in termination {
                    code = status
                }
                continuation.yield(.exited(code: code, standardError: await errorText))
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    public func send(line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !inputClosed else { return }
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !inputClosed else { return }
        inputClosed = true
        try? input.fileHandleForWriting.close()
    }

    public func terminate() {
        closeInput()
        if process.isRunning {
            process.terminate()
        }
    }

    public func kill() {
        closeInput()
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func readAll(_ handle: FileHandle) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data.suffix(16_384), as: UTF8.self))
            }
        }
    }
}
