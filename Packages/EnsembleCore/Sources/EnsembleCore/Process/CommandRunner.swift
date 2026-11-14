import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }
}

public struct CommandError: Error, LocalizedError, Sendable {
    public let command: String
    public let result: CommandResult

    public var errorDescription: String? {
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "\(command) exited with code \(result.exitCode)"
        }
        return message
    }
}

public struct CommandRunner: Sendable, Equatable {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        try process.run()

        async let output = Self.readToEnd(outputPipe.fileHandleForReading)
        async let error = Self.readToEnd(errorPipe.fileHandleForReading)

        var exitCode: Int32 = -1
        for await status in termination {
            exitCode = status
        }

        return CommandResult(
            exitCode: exitCode,
            standardOutput: String(decoding: await output, as: UTF8.self),
            standardError: String(decoding: await error, as: UTF8.self)
        )
    }

    public func runChecked(_ executable: URL, _ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        let result = try await run(executable, arguments, in: directory)
        guard result.succeeded else {
            let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            throw CommandError(command: command, result: result)
        }
        return result
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
