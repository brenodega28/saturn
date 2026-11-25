import Foundation

public struct CheckResult: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable {
        case passed
        case failed
        case timedOut = "timed_out"
        case couldNotRun = "could_not_run"
    }

    public var name: String
    public var kind: CheckKind
    public var command: String
    public var status: Status
    public var exitCode: Int32?
    public var durationSeconds: Double
    public var output: String
    public var logPath: String?

    public var id: String { name }
    public var passed: Bool { status == .passed }

    public init(
        name: String, kind: CheckKind, command: String, status: Status, exitCode: Int32? = nil,
        durationSeconds: Double = 0, output: String = "", logPath: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.output = output
        self.logPath = logPath
    }

    public var headline: String {
        switch status {
        case .passed: "\(name) passed"
        case .failed: "\(name) failed (exit \(exitCode ?? -1))"
        case .timedOut: "\(name) timed out"
        case .couldNotRun: "\(name) couldn’t run"
        }
    }
}

public struct CheckReport: Sendable, Hashable, Codable {
    public var agentName: String?
    public var branch: String?
    public var round: Int
    public var results: [CheckResult]
    public var notes: [String]

    public init(agentName: String? = nil, branch: String? = nil, round: Int = 1, results: [CheckResult], notes: [String] = []) {
        self.agentName = agentName
        self.branch = branch
        self.round = round
        self.results = results
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
        self.round = try container.decodeIfPresent(Int.self, forKey: .round) ?? 1
        self.results = try container.decodeIfPresent([CheckResult].self, forKey: .results) ?? []
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public var passed: Bool { results.allSatisfy(\.passed) && notes.isEmpty }
    public var failures: [CheckResult] { results.filter { !$0.passed } }

    public var summary: String {
        let owner = agentName.map { "\($0): " } ?? ""
        guard !passed else { return owner + "all \(results.count) checks passed" }
        return owner + (failures.map(\.headline) + notes).joined(separator: "; ")
    }

    public func failureDetails(outputLines: Int = 40) -> String {
        var parts = failures.map { result in
            let output = result.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(outputLines).joined(separator: "\n")
            return "### \(result.headline)\nCommand: `\(result.command)`\n```\n\(output.isEmpty ? "(no output)" : output)\n```"
        }
        parts += notes
        return parts.joined(separator: "\n\n")
    }
}

public struct CheckRunner: Sendable {
    public static let outputLineCount = 60

    public var environment: [String: String]
    public var killGracePeriod: Duration
    public var minute: Duration

    public init(environment: [String: String], killGracePeriod: Duration = .seconds(3), minute: Duration = .seconds(60)) {
        self.environment = environment
        self.killGracePeriod = killGracePeriod
        self.minute = minute
    }

    public func run(_ checks: [CheckDefinition], in directory: URL, variables: [String: String] = [:], logDirectory: URL) async -> [CheckResult] {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        var results: [CheckResult] = []
        for check in checks {
            results.append(await run(check, in: directory, variables: variables, logDirectory: logDirectory))
        }
        return results
    }

    public func run(_ check: CheckDefinition, in directory: URL, variables: [String: String] = [:], logDirectory: URL) async -> CheckResult {
        let log = logDirectory.appending(path: "\(Slug.make(check.name).nilIfEmpty ?? "check").log")
        let started = ContinuousClock.now
        var result = CheckResult(name: check.name, kind: check.kind, command: check.command, status: .couldNotRun, logPath: log.path)
        do {
            let timeout = minute * max(1, check.timeoutMinutes)
            let outcome = try await ShellScript.run(
                check.command, in: directory, environment: environment.merging(variables) { _, new in new },
                log: log, timeout: timeout, killGracePeriod: killGracePeriod
            )
            switch outcome {
            case .exited(0):
                result.status = .passed
                result.exitCode = 0
            case .exited(let code):
                result.status = .failed
                result.exitCode = code
            case .timedOut:
                result.status = .timedOut
            }
            result.output = ShellScript.tail(of: log, lines: Self.outputLineCount)
        } catch {
            result.output = error.localizedDescription
        }
        result.durationSeconds = (ContinuousClock.now - started) / .seconds(1)
        return result
    }
}
