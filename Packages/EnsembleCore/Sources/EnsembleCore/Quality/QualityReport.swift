import Foundation
import GRDB
import Yams

public struct QualityWeek: Sendable, Hashable, Identifiable {
    public var start: Date
    public var approvedChanges = 0
    public var changeSizes: [Int] = []
    public var approvalMinutes: [Double] = []
    public var checkRuns = 0
    public var checkRunsFailingFirst = 0
    public var checkRetries = 0
    public var approvals = 0
    public var sentBack = 0
    public var reworkedRuns = 0
    public var finishedRuns = 0
    public var duplicationWarnings = 0
    public var complexityWarnings = 0
    public var costUSD: Double = 0
    public var failingChecks: [String: Int] = [:]
    public var rulesAdded = 0

    public var id: Date { start }

    public var medianChangeSize: Int? { Self.median(changeSizes.map(Double.init)).map { Int($0.rounded()) } }
    public var medianApprovalMinutes: Double? { Self.median(approvalMinutes) }
    public var checkFailureRate: Double? { checkRuns == 0 ? nil : Double(checkRunsFailingFirst) / Double(checkRuns) }
    public var reworkRate: Double? { finishedRuns == 0 ? nil : Double(reworkedRuns) / Double(finishedRuns) }
    public var costPerApprovedChange: Double? { approvedChanges == 0 ? nil : costUSD / Double(approvedChanges) }
    public var mostFailingCheck: String? { failingChecks.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

public struct QualityReport: Sendable, Hashable {
    public var weeks: [QualityWeek]

    public init(weeks: [QualityWeek]) {
        self.weeks = weeks
    }

    public var current: QualityWeek? { weeks.last }

    public var total: QualityWeek {
        weeks.reduce(into: QualityWeek(start: weeks.first?.start ?? .now)) { total, week in
            total.approvedChanges += week.approvedChanges
            total.changeSizes += week.changeSizes
            total.approvalMinutes += week.approvalMinutes
            total.checkRuns += week.checkRuns
            total.checkRunsFailingFirst += week.checkRunsFailingFirst
            total.checkRetries += week.checkRetries
            total.approvals += week.approvals
            total.sentBack += week.sentBack
            total.reworkedRuns += week.reworkedRuns
            total.finishedRuns += week.finishedRuns
            total.duplicationWarnings += week.duplicationWarnings
            total.complexityWarnings += week.complexityWarnings
            total.costUSD += week.costUSD
            total.rulesAdded += week.rulesAdded
            total.failingChecks.merge(week.failingChecks, uniquingKeysWith: +)
        }
    }
}

extension AppDatabase {
    public func qualityReport(projectIds: [Int64], weeks count: Int = 8, now: Date = .now, calendar: Calendar = .current) throws -> QualityReport {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(count - 1), to: thisWeek) else { return QualityReport(weeks: []) }
        var weeks = (0..<count).compactMap { offset in calendar.date(byAdding: .weekOfYear, value: offset, to: first).map { QualityWeek(start: $0) } }
        func bucket(_ date: Date?) -> Int? {
            guard let date, date >= first, let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
            return weeks.firstIndex { $0.start == start }
        }

        let (runs, steps, items, corrections) = try writer.read { db in
            (
                try Run.filter(projectIds.contains(Column("projectId"))).fetchAll(db),
                try RunStep.fetchAll(db),
                try InboxItem.filter(projectIds.contains(Column("projectId"))).filter(Column("kind") == InboxKind.approval.rawValue).fetchAll(db),
                try Correction.filter(projectIds.contains(Column("projectId"))).filter(Column("encodedAt") != nil).fetchAll(db)
            )
        }
        let stepsByRun = Dictionary(grouping: steps, by: \.runId)
        let decoder = JSONDecoder()
        func output(_ step: RunStep) -> StepOutput? {
            step.output.flatMap { try? decoder.decode(StepOutput.self, from: Data($0.utf8)) }
        }

        for run in runs {
            guard let id = run.id else { continue }
            let workflow = try? YAMLDecoder().decode(WorkflowDefinition.self, from: run.workflowSnapshot)
            let runSteps = stepsByRun[id] ?? []
            if [.succeeded, .failed, .cancelled].contains(run.status), let index = bucket(run.endedAt) {
                weeks[index].finishedRuns += 1
                let reworked = runSteps.contains { $0.outcome == StepOutcome.changesRequested && workflow?.step($0.stepId)?.type != .agent }
                if reworked { weeks[index].reworkedRuns += 1 }
                if run.status == .succeeded {
                    weeks[index].approvedChanges += 1
                    weeks[index].costUSD += run.costUSD
                    if let lines = run.linesChanged { weeks[index].changeSizes.append(lines) }
                }
            }
            for step in runSteps {
                guard let type = workflow?.step(step.stepId)?.type, let index = bucket(step.endedAt ?? step.startedAt) else { continue }
                switch type {
                case .check:
                    guard [.succeeded, .failed].contains(step.status) else { continue }
                    let reports = output(step)?.checks ?? []
                    let rounds = reports.map(\.round).max() ?? 1
                    weeks[index].checkRuns += 1
                    if rounds > 1 || step.status == .failed { weeks[index].checkRunsFailingFirst += 1 }
                    weeks[index].checkRetries += max(0, rounds - 1)
                    for result in reports.flatMap(\.results) where !result.passed {
                        weeks[index].failingChecks[result.name, default: 0] += 1
                    }
                    if step.status == .failed {
                        for name in failingCheckNames(in: step.output) { weeks[index].failingChecks[name, default: 0] += 1 }
                    }
                case .gates:
                    let warnings = output(step)?.gates?.warnings ?? []
                    weeks[index].duplicationWarnings += warnings.count { $0.kind == .duplication }
                    weeks[index].complexityWarnings += warnings.count { $0.kind == .complexity }
                case .approval:
                    guard step.status == .succeeded else { continue }
                    weeks[index].approvals += 1
                    if step.outcome == StepOutcome.changesRequested { weeks[index].sentBack += 1 }
                default:
                    continue
                }
            }
        }
        for item in items where item.status == .resolved {
            guard let resolved = item.resolvedAt, let index = bucket(resolved) else { continue }
            weeks[index].approvalMinutes.append(resolved.timeIntervalSince(item.createdAt) / 60)
        }
        for correction in corrections {
            if let index = bucket(correction.encodedAt) { weeks[index].rulesAdded += 1 }
        }
        return QualityReport(weeks: weeks)
    }

    private func failingCheckNames(in output: String?) -> [String] {
        guard let summary = output.flatMap({ try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) })?.summary else { return [] }
        return summary.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("## ") else { return nil }
            return line.split(separator: ":").dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces).components(separatedBy: " failed").first ?? "" }
        }.filter { !$0.isEmpty }
    }
}
