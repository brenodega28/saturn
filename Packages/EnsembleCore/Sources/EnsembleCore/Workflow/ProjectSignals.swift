import Foundation

public struct ProjectProblem: Sendable, Hashable, Identifiable {
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case failingChecks
        case gateFindings
        case configErrors
        case missingSkills

        public var title: String {
            switch self {
            case .failingChecks: "Failing checks"
            case .gateFindings: "Gate findings"
            case .configErrors: "Config errors"
            case .missingSkills: "Missing skills"
            }
        }
    }

    public enum Severity: String, Sendable, Hashable {
        case error
        case warning
    }

    public var category: Category
    public var severity: Severity
    public var title: String
    public var location: String
    public var file: String?
    public var line: Int?
    public var runId: Int64?

    public init(category: Category, severity: Severity, title: String, location: String, file: String? = nil, line: Int? = nil, runId: Int64? = nil) {
        self.category = category
        self.severity = severity
        self.title = title
        self.location = location
        self.file = file
        self.line = line
        self.runId = runId
    }

    public var id: String {
        [category.rawValue, runId.map(String.init) ?? "", file ?? "", line.map(String.init) ?? "", title].joined(separator: "|")
    }
}

public struct CheckBoardEntry: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        case running
        case passed
        case failed
        case exhausted
    }

    public var runId: Int64
    public var runTitle: String
    public var agentName: String?
    public var branch: String?
    public var round: Int
    public var results: [CheckResult]
    public var state: State
    public var message: String?

    public init(runId: Int64, runTitle: String, agentName: String? = nil, branch: String? = nil, round: Int = 1, results: [CheckResult] = [], state: State, message: String? = nil) {
        self.runId = runId
        self.runTitle = runTitle
        self.agentName = agentName
        self.branch = branch
        self.round = round
        self.results = results
        self.state = state
        self.message = message
    }

    public var id: String {
        "\(runId)|\(agentName ?? "")|\(branch ?? "")"
    }
}

public enum ProjectSignals {
    public static let activeStatuses: Set<RunStatus> = [.pending, .running, .waitingOnYou, .paused, .interrupted]

    public static func output(of step: RunStep) -> StepOutput? {
        step.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }
    }

    public static func checkBoard(runs: [Run], steps: [Int64: [RunStep]], holds: [Int64: RunHold] = [:]) -> [CheckBoardEntry] {
        runs.filter { activeStatuses.contains($0.status) }.flatMap { run -> [CheckBoardEntry] in
            guard let runId = run.id else { return [] }
            let workflow = run.snapshotWorkflow
            let runSteps = (steps[runId] ?? []).sorted { $0.startedAt < $1.startedAt }
            let checkSteps = runSteps.filter { step in
                workflow?.step(step.stepId)?.type == .check || !(output(of: step)?.checks.isEmpty ?? true)
            }
            let reports = checkSteps.reversed().lazy.compactMap { output(of: $0)?.checks }.first { !$0.isEmpty } ?? []
            var entries = reports.map { report in
                CheckBoardEntry(
                    runId: runId, runTitle: run.title, agentName: report.agentName, branch: report.branch,
                    round: report.round, results: report.results, state: report.passed ? .passed : .failed
                )
            }
            if let hold = holds[runId], hold.isChecksExhausted(in: workflow) {
                let message = hold.message.split(separator: "\n").first.map(String.init) ?? hold.message
                if entries.isEmpty {
                    entries = [CheckBoardEntry(runId: runId, runTitle: run.title, state: .exhausted, message: message)]
                } else {
                    entries = entries.map { var entry = $0; entry.state = .exhausted; entry.message = message; return entry }
                }
            } else if checkSteps.last?.status == .running {
                if entries.isEmpty {
                    entries = [CheckBoardEntry(runId: runId, runTitle: run.title, state: .running)]
                } else {
                    entries = entries.map { var entry = $0; entry.state = .running; entry.round += 1; return entry }
                }
            }
            return entries
        }
    }

    public static func problems(
        runs: [Run], steps: [Int64: [RunStep]], holds: [Int64: RunHold] = [:], configIssues: [ConfigIssue] = [],
        agents: [Agent] = [], installedSkills: Set<String> = []
    ) -> [ProjectProblem] {
        var problems: [ProjectProblem] = []
        for run in runs where activeStatuses.contains(run.status) {
            guard let runId = run.id else { continue }
            if let hold = holds[runId], hold.isChecksExhausted(in: run.snapshotWorkflow) {
                let headline = hold.message.split(separator: "\n").first.map(String.init) ?? hold.message
                problems.append(ProjectProblem(category: .failingChecks, severity: .error, title: headline, location: run.title, runId: runId))
            }
            for entry in checkBoard(runs: [run], steps: steps) where entry.state == .failed {
                for result in entry.results where !result.passed {
                    problems.append(ProjectProblem(
                        category: .failingChecks, severity: .error, title: "\(result.name) failed in round \(entry.round)",
                        location: [entry.agentName, entry.branch].compactMap(\.self).joined(separator: " · "), runId: runId
                    ))
                }
            }
            let gates = (steps[runId] ?? []).sorted { $0.startedAt < $1.startedAt }.reversed().lazy.compactMap { output(of: $0)?.gates }.first
            for finding in gates?.findings ?? [] {
                let place = finding.file.map { path in finding.line.map { "\(path):\($0)" } ?? path }
                problems.append(ProjectProblem(
                    category: .gateFindings, severity: finding.severity == .blocking ? .error : .warning, title: finding.title,
                    location: [place, run.title].compactMap(\.self).joined(separator: " · "), file: finding.file, line: finding.line, runId: runId
                ))
            }
        }
        for issue in configIssues {
            problems.append(ProjectProblem(category: .configErrors, severity: .error, title: issue.message, location: issue.file, file: issue.file))
        }
        var skillOrder: [String] = []
        var agentsBySkill: [String: [String]] = [:]
        for agent in agents where agent.archivedAt == nil {
            for skill in agent.skills where !installedSkills.contains(skill) {
                if agentsBySkill[skill] == nil { skillOrder.append(skill) }
                agentsBySkill[skill, default: []].append(AgentNaming.displayName(of: agent))
            }
        }
        for skill in skillOrder {
            problems.append(ProjectProblem(
                category: .missingSkills, severity: .warning, title: "\(skill) was chosen for an agent but isn’t installed",
                location: (agentsBySkill[skill] ?? []).joined(separator: ", ")
            ))
        }
        return problems
    }
}
