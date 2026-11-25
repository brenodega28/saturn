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
        let stream = try process.start(launch)
        return (process, stream)
    }
}

public final class ClaudeProcess: AgentProcessHandle, @unchecked Sendable {
    private static let ignoreBrokenPipes: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private let process = Process()
    private let drainGrace: Duration
    private let input = Pipe()
    private let lock = NSLock()
    private var inputClosed = false

    public init(drainGrace: Duration = .seconds(2)) {
        self.drainGrace = drainGrace
        Self.ignoreBrokenPipes
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public var isRunning: Bool { process.isRunning }

    func start(_ launch: ClaudeLaunch) throws -> AsyncStream<ProcessOutput> {
        let output = Pipe()
        let errors = Pipe()
        let invocation = launch.invocation
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.directory
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

        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self)
        let lines = OutputCollector { continuation.yield(.line($0)) }
        let errorText = OutputCollector(limit: 16_384)
        lines.attach(to: output.fileHandleForReading)
        errorText.attach(to: errors.fileHandleForReading)

        let drainGrace = self.drainGrace
        let waiter = Task.detached {
            var code: Int32 = -1
            for await status in termination {
                code = status
            }
            let deadline = ContinuousClock.now + drainGrace
            while !lines.isFinished, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            lines.detach(from: output.fileHandleForReading)
            errorText.detach(from: errors.fileHandleForReading)
            continuation.yield(.exited(code: code, standardError: errorText.text))
            continuation.finish()
        }
        continuation.onTermination = { _ in waiter.cancel() }
        return stream
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
        guard process.isRunning else { return }
        let root = process.processIdentifier
        for pid in Self.descendants(of: root).reversed() {
            Darwin.kill(pid, SIGKILL)
        }
        Darwin.kill(root, SIGKILL)
    }

    static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        while let parent = queue.popLast() {
            var children = [Int32](repeating: 0, count: 256)
            let bytes = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<Int32>.size))
            let count = max(0, Int(bytes))
            let found = children.prefix(count).filter { $0 > 0 }
            result.append(contentsOf: found)
            queue.append(contentsOf: found)
        }
        return result
    }

}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (String) -> Void)?
    private let limit: Int?
    private var buffer = Data()
    private var collected = Data()
    private var finished = false

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
        self.limit = nil
    }

    init(limit: Int) {
        self.onLine = nil
        self.limit = limit
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    var text: String {
        lock.withLock { String(decoding: collected, as: UTF8.self) }
    }

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finish()
            } else {
                receive(data)
            }
        }
    }

    func detach(from handle: FileHandle) {
        handle.readabilityHandler = nil
        finish()
        try? handle.close()
    }

    private func receive(_ data: Data) {
        guard let onLine else {
            lock.withLock {
                collected.append(data)
                if let limit, collected.count > limit {
                    collected = collected.suffix(limit)
                }
            }
            return
        }
        let ready: [String] = lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        ready.forEach(onLine)
    }

    private func finish() {
        let remainder: String? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard onLine != nil, !buffer.isEmpty else { return nil }
            defer { buffer.removeAll() }
            return String(decoding: buffer, as: UTF8.self)
        }
        if let remainder, let onLine { onLine(remainder) }
    }
}
