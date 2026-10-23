import Darwin
import Foundation
import Synchronization

public struct SetupRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case timedOut
    }

    public var status: Status
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var tail: String

    public init(status: Status, startedAt: Date, endedAt: Date? = nil, exitCode: Int32? = nil, tail: String = "") {
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.tail = tail
    }

    public static let logFileName = "setup.log"
    public static let recordFileName = "setup.json"

    public static func logFile(in directory: URL) -> URL {
        directory.appending(path: logFileName)
    }

    public static func recordFile(in directory: URL) -> URL {
        directory.appending(path: recordFileName)
    }

    public static func load(from directory: URL) -> SetupRecord? {
        guard let data = try? Data(contentsOf: recordFile(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SetupRecord.self, from: data)
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.recordFile(in: directory), options: .atomic)
    }
}

public enum SetupScriptError: Error, LocalizedError, Equatable {
    case failed(exitCode: Int32, tail: String)
    case timedOut(minutes: Int, tail: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let code, let tail):
            "The setup script exited with code \(code)." + Self.suffix(tail)
        case .timedOut(let minutes, let tail):
            "The setup script didn’t finish within \(minutes) minute\(minutes == 1 ? "" : "s")." + Self.suffix(tail)
        case .launchFailed(let reason):
            "The setup script couldn’t start: \(reason)"
        }
    }

    private static func suffix(_ tail: String) -> String {
        tail.isEmpty ? "" : "\n" + tail
    }
}

public struct SetupScriptRunner: Sendable {
    public static let shell = URL(fileURLWithPath: "/bin/zsh")
    public static let tailLineCount = 12

    public var environment: [String: String]
    public var timeout: Duration
    public var killGracePeriod: Duration

    public init(environment: [String: String], timeout: Duration = .seconds(600), killGracePeriod: Duration = .seconds(3)) {
        self.environment = environment
        self.timeout = timeout
        self.killGracePeriod = killGracePeriod
    }

    @discardableResult
    public func run(script: String, in directory: URL, variables: [String: String], logDirectory: URL) async throws -> SetupRecord {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let log = SetupRecord.logFile(in: logDirectory)
        var record = SetupRecord(status: .running, startedAt: .now)
        try record.save(in: logDirectory)

        let outcome: ScriptOutcome
        do {
            outcome = try await execute(script: script, in: directory, variables: variables, log: log)
        } catch {
            record.status = .failed
            record.endedAt = .now
            record.tail = error.localizedDescription
            try? record.save(in: logDirectory)
            throw SetupScriptError.launchFailed(error.localizedDescription)
        }

        record.endedAt = .now
        record.tail = Self.tail(of: log)
        switch outcome {
        case .exited(0):
            record.status = .succeeded
            record.exitCode = 0
            try record.save(in: logDirectory)
            return record
        case .exited(let code):
            record.status = .failed
            record.exitCode = code
            try? record.save(in: logDirectory)
            throw SetupScriptError.failed(exitCode: code, tail: record.tail)
        case .timedOut:
            record.status = .timedOut
            try? record.save(in: logDirectory)
            throw SetupScriptError.timedOut(minutes: max(1, Int(timeout.components.seconds / 60)), tail: record.tail)
        }
    }

    public static func tail(of log: URL, lines count: Int = tailLineCount) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }

    enum ScriptOutcome: Equatable {
        case exited(Int32)
        case timedOut
    }

    private func execute(script: String, in directory: URL, variables: [String: String], log: URL) async throws -> ScriptOutcome {
        let logDescriptor = open(log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard logDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(logDescriptor) }

        let processEnvironment = environment.merging(variables) { _, new in new }
        let pid = try Self.spawn(
            arguments: [Self.shell.path, "-lc", script],
            environment: processEnvironment.map { "\($0.key)=\($0.value)" },
            directory: directory.path,
            output: logDescriptor
        )

        let timedOut = Mutex(false)
        let watchdog = Task { [timeout, killGracePeriod] in
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            kill(-pid, SIGTERM)
            try await Task.sleep(for: killGracePeriod)
            kill(-pid, SIGKILL)
        }
        let status = await withTaskCancellationHandler {
            await Self.waitForExit(pid)
        } onCancel: {
            kill(-pid, SIGKILL)
        }
        watchdog.cancel()

        if timedOut.withLock({ $0 }) {
            kill(-pid, SIGKILL)
            return .timedOut
        }
        let signal = status & 0x7f
        return .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }

    private static func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }

    private static func spawn(arguments: [String], environment: [String], directory: String, output: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}
