import Foundation

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
    public static let shell = ShellScript.shell
    public static let tailLineCount = 12

    public var environment: [String: String]
    public var timeout: Duration
    public var killGracePeriod: Duration
    public var remote: RemoteAgentHost?

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

        let outcome: ShellScript.Outcome
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
        ShellScript.tail(of: log, lines: count)
    }

    private func execute(script: String, in directory: URL, variables: [String: String], log: URL) async throws -> ShellScript.Outcome {
        if let remote {
            return try await ShellScript.runRemote(
                script, on: remote.client, in: directory, variables: variables,
                pidFile: remote.stateDirectory(named: "setup/\(UUID().uuidString).pid"),
                log: log, timeout: timeout, killGracePeriod: killGracePeriod
            )
        }
        return try await ShellScript.run(
            script, in: directory, environment: environment.merging(variables) { _, new in new },
            log: log, timeout: timeout, killGracePeriod: killGracePeriod
        )
    }
}
