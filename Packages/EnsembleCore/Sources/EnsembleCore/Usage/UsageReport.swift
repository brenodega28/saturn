import Foundation
import GRDB

public struct UsageBreakdownRow: Sendable, Hashable, Identifiable {
    public var key: String
    public var title: String
    public var detail: String?
    public var costUSD: Double
    public var tokens: Int
    public var turns: Int

    public var id: String { key }

    public init(key: String, title: String, detail: String? = nil, costUSD: Double, tokens: Int, turns: Int) {
        self.key = key
        self.title = title
        self.detail = detail
        self.costUSD = costUSD
        self.tokens = tokens
        self.turns = turns
    }
}

public struct ExpensiveTurn: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var projectName: String
    public var agentName: String?
    public var role: String?
    public var runTitle: String?
    public var model: String
    public var tokens: Int
    public var costUSD: Double
    public var recordedAt: Date
}

public enum UsagePeriod: String, CaseIterable, Sendable, Identifiable {
    case week
    case month
    case allTime

    public var id: Self { self }

    public var title: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .allTime: "All time"
        }
    }

    public func start(at date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .month: BudgetMonth.start(of: date, calendar: calendar)
        case .allTime: nil
        }
    }
}

public struct UsageTotals: Sendable, Hashable {
    public var weekUSD: Double
    public var monthUSD: Double
    public var allTimeUSD: Double

    public init(weekUSD: Double = 0, monthUSD: Double = 0, allTimeUSD: Double = 0) {
        self.weekUSD = weekUSD
        self.monthUSD = monthUSD
        self.allTimeUSD = allTimeUSD
    }
}

public struct UsageReport: Sendable, Hashable {
    public var totals: UsageTotals
    public var byProject: [UsageBreakdownRow]
    public var byRun: [UsageBreakdownRow]
    public var byRole: [UsageBreakdownRow]
    public var byModel: [UsageBreakdownRow]
    public var expensiveTurns: [ExpensiveTurn]

    public var isEmpty: Bool { totals.allTimeUSD == 0 && byProject.isEmpty }
}

extension AppDatabase {
    public func usageTotals(at date: Date = .now, calendar: Calendar = .current) throws -> UsageTotals {
        try writer.read { db in
            func total(since start: Date?) throws -> Double {
                if let start {
                    return try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM usage WHERE recordedAt >= ?", arguments: [start]) ?? 0
                }
                return try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM usage") ?? 0
            }
            return UsageTotals(
                weekUSD: try total(since: UsagePeriod.week.start(at: date, calendar: calendar)),
                monthUSD: try total(since: UsagePeriod.month.start(at: date, calendar: calendar)),
                allTimeUSD: try total(since: nil)
            )
        }
    }

    public func usageReport(
        period: UsagePeriod,
        projectId: Int64? = nil,
        at date: Date = .now,
        calendar: Calendar = .current,
        runLimit: Int = 12,
        expensiveTurnLimit: Int = 10
    ) throws -> UsageReport {
        let totals = try usageTotals(at: date, calendar: calendar)
        let start = period.start(at: date, calendar: calendar)
        return try writer.read { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            if let start {
                conditions.append("usage.recordedAt >= ?")
                _ = arguments.append(contentsOf: [start])
            }
            if let projectId {
                conditions.append("usage.projectId = ?")
                _ = arguments.append(contentsOf: [projectId])
            }
            let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let measures = "SUM(usage.costUSD) AS cost, SUM(usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens) AS tokens, COUNT(*) AS turns"

            func rows(_ sql: String, limit: Int? = nil, map: (Row) -> (key: String, title: String, detail: String?)) throws -> [UsageBreakdownRow] {
                let limited = limit.map { sql + " LIMIT \($0)" } ?? sql
                return try Row.fetchAll(db, sql: limited, arguments: arguments).map { row in
                    let label = map(row)
                    return UsageBreakdownRow(
                        key: label.key, title: label.title, detail: label.detail,
                        costUSD: row["cost"] ?? 0, tokens: row["tokens"] ?? 0, turns: row["turns"] ?? 0
                    )
                }
            }

            let byProject = try rows("""
                SELECT usage.projectId AS projectId, project.name AS name, \(measures)
                FROM usage JOIN project ON project.id = usage.projectId
                \(filter) GROUP BY usage.projectId ORDER BY cost DESC, name
                """) { row in
                let id: Int64 = row["projectId"]
                return ("project-\(id)", row["name"] ?? "Project", nil)
            }

            let byRun = try rows("""
                SELECT usage.runId AS runId, run.title AS title, run.workflow AS workflow, run.status AS status, project.name AS projectName, \(measures)
                FROM usage LEFT JOIN run ON run.id = usage.runId JOIN project ON project.id = usage.projectId
                \(filter) GROUP BY usage.runId ORDER BY (usage.runId IS NULL), cost DESC
                """) { row in
                guard let runId: Int64 = row["runId"] else {
                    return ("run-none", "Outside runs", "Agents you spawned yourself")
                }
                let title: String = row["title"] ?? ""
                let detail = [row["projectName"] as String?, row["workflow"] as String?].compactMap(\.self).joined(separator: " · ")
                return ("run-\(runId)", title.isEmpty ? "Run #\(runId)" : title, detail.isEmpty ? nil : detail)
            }
            let ranRuns = byRun.filter { $0.key != "run-none" }
            let outsideRuns = byRun.filter { $0.key == "run-none" }
            let limitedRuns = Array(ranRuns.prefix(runLimit)) + outsideRuns

            let byRole = try rows("""
                SELECT agent.role AS role, \(measures)
                FROM usage LEFT JOIN agent ON agent.id = usage.agentId
                \(filter) GROUP BY agent.role ORDER BY cost DESC
                """) { row in
                guard let role: String = row["role"] else { return ("role-none", "Deleted agents", "Role unknown") }
                return ("role-\(role)", role, nil)
            }

            let byModel = try rows("""
                SELECT usage.model AS model, \(measures)
                FROM usage \(filter) GROUP BY usage.model ORDER BY cost DESC
                """) { row in
                let model: String = row["model"] ?? "unknown"
                return ("model-\(model)", model, nil)
            }

            let expensive = try Row.fetchAll(db, sql: """
                SELECT usage.id AS id, usage.model AS model, usage.costUSD AS cost, usage.recordedAt AS recordedAt,
                       usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens AS tokens,
                       project.name AS projectName, agent.name AS agentName, agent.role AS role, run.title AS runTitle
                FROM usage
                JOIN project ON project.id = usage.projectId
                LEFT JOIN agent ON agent.id = usage.agentId
                LEFT JOIN run ON run.id = usage.runId
                \(filter) ORDER BY usage.costUSD DESC, usage.recordedAt DESC LIMIT \(expensiveTurnLimit)
                """, arguments: arguments).map { row in
                ExpensiveTurn(
                    id: row["id"], projectName: row["projectName"] ?? "Project", agentName: row["agentName"], role: row["role"],
                    runTitle: (row["runTitle"] as String?).flatMap { $0.isEmpty ? nil : $0 }, model: row["model"] ?? "unknown",
                    tokens: row["tokens"] ?? 0, costUSD: row["cost"] ?? 0, recordedAt: row["recordedAt"]
                )
            }

            return UsageReport(
                totals: totals, byProject: byProject, byRun: limitedRuns, byRole: byRole, byModel: byModel, expensiveTurns: expensive
            )
        }
    }
}
