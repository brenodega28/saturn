import Foundation

public struct ChatChecks: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case waitingForWorkers
        case notStarted
        case running(round: Int)
        case failed(round: Int, maxRounds: Int)
        case exhausted(round: Int)
        case passed(count: Int)
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public enum Status: String, Sendable, Hashable {
            case passed
            case failed
            case running
        }

        public var name: String
        public var status: Status
        public var durationSeconds: Double

        public var id: String { name }
    }

    public var state: State
    public var rows: [Row]

    public static func make(run: Run?, workflow: WorkflowDefinition?, steps: [RunStep], hold: RunHold?, hasWorkers: Bool) -> ChatChecks {
        guard let run else { return ChatChecks(state: hasWorkers ? .notStarted : .waitingForWorkers, rows: []) }
        let checkSteps = steps
            .filter { $0.runId == run.id && (workflow?.step($0.stepId)?.type == .check || !(ProjectSignals.output(of: $0)?.checks.isEmpty ?? true)) }
            .sorted { ($0.startedAt, $0.id ?? 0) < ($1.startedAt, $1.id ?? 0) }
        guard let latest = checkSteps.last else {
            return ChatChecks(state: hasWorkers ? .notStarted : .waitingForWorkers, rows: [])
        }
        let reports = checkSteps.reversed().lazy.compactMap { ProjectSignals.output(of: $0)?.checks }.first { !$0.isEmpty } ?? []
        let rows = Self.rows(from: reports, running: latest.status == .running)
        let round = latest.iteration
        if let hold, hold.isChecksExhausted(in: workflow) {
            return ChatChecks(state: .exhausted(round: round), rows: rows)
        }
        if latest.status == .running {
            return ChatChecks(state: .running(round: round), rows: rows)
        }
        let maxRounds = workflow?.step(latest.stepId)?.maxRounds ?? ChecksConfig.defaultMaxRounds
        if reports.isEmpty || reports.allSatisfy(\.passed) {
            return ChatChecks(state: .passed(count: rows.count), rows: rows)
        }
        return ChatChecks(state: .failed(round: round, maxRounds: maxRounds), rows: rows)
    }

    static func rows(from reports: [CheckReport], running: Bool) -> [Row] {
        var order: [String] = []
        var merged: [String: Row] = [:]
        for result in reports.flatMap(\.results) {
            if merged[result.name] == nil { order.append(result.name) }
            var row = merged[result.name] ?? Row(name: result.name, status: .passed, durationSeconds: 0)
            if !result.passed { row.status = .failed }
            row.durationSeconds = max(row.durationSeconds, result.durationSeconds)
            merged[result.name] = row
        }
        return order.compactMap { name in
            guard var row = merged[name] else { return nil }
            if running { row.status = .running }
            return row
        }
    }
}
