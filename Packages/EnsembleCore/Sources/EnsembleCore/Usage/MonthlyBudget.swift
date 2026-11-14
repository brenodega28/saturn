import Foundation
import GRDB

public enum BudgetThreshold: Int, CaseIterable, Sendable, Comparable {
    case warning = 80
    case reached = 100

    public var fraction: Double { Double(rawValue) / 100 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func crossed(spent: Double, budget: Double?) -> [BudgetThreshold] {
        guard let budget, budget > 0 else { return [] }
        return allCases.filter { spent >= budget * $0.fraction - 0.000_001 }
    }
}

public enum BudgetMonth {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public static func start(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    public static func title(for date: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle().month(.wide).year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

public enum BudgetWeek {
    public static func start(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: start(of: date, calendar: calendar))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func title(for date: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "the week of " + start(of: date, calendar: calendar).formatted(style)
    }
}

public struct BudgetStatus: Sendable, Hashable {
    public var budgetUSD: Double?
    public var spentUSD: Double
    public var allowedOverBudget: Bool

    public init(budgetUSD: Double?, spentUSD: Double, allowedOverBudget: Bool = false) {
        self.budgetUSD = budgetUSD
        self.spentUSD = spentUSD
        self.allowedOverBudget = allowedOverBudget
    }

    public var fractionUsed: Double? {
        guard let budgetUSD, budgetUSD > 0 else { return nil }
        return spentUSD / budgetUSD
    }

    public var crossedThresholds: [BudgetThreshold] {
        BudgetThreshold.crossed(spent: spentUSD, budget: budgetUSD)
    }

    public var isReached: Bool { crossedThresholds.contains(.reached) }

    public var blocksNewWork: Bool { isReached && !allowedOverBudget }
}

public enum BudgetError: Error, LocalizedError, Equatable {
    case projectMonthlyBudgetReached(project: String, budgetUSD: Double, spentUSD: Double)
    case projectWeeklyBudgetReached(project: String, budgetUSD: Double, spentUSD: Double)

    public var errorDescription: String? {
        switch self {
        case .projectWeeklyBudgetReached(let project, let budget, let spent):
            "\(project) has spent \(spent.formatted(.currency(code: "USD"))) of its \(budget.formatted(.currency(code: "USD"))) weekly budget, so Ensemble isn’t starting new runs or agent turns. Raise the budget or choose “Allow this week” in Usage or Settings › Agents & models."
        case .projectMonthlyBudgetReached(let project, let budget, let spent):
            "\(project) has spent \(spent.formatted(.currency(code: "USD"))) of its \(budget.formatted(.currency(code: "USD"))) monthly budget, so Ensemble isn’t starting new runs or agent turns. Raise the budget or choose “Allow this month” in Usage or Settings › Agents & models."
        }
    }
}

extension ProjectSettings {
    public func allowsOverBudget(at date: Date, calendar: Calendar = .current) -> Bool {
        budgetOverrideMonth == BudgetMonth.key(for: date, calendar: calendar)
    }

    public func allowsOverWeeklyBudget(at date: Date, calendar: Calendar = .current) -> Bool {
        budgetOverrideWeek == BudgetWeek.key(for: date, calendar: calendar)
    }
}

public enum BudgetNoticeScope: Sendable, Hashable {
    case project
    case global
}

public struct BudgetNotice: Sendable, Hashable {
    public var scope: BudgetNoticeScope
    public var threshold: BudgetThreshold
    public var projectId: Int64
    public var title: String
    public var body: String
}

extension AppDatabase {
    public func monthlySpend(projectId: Int64? = nil, at date: Date = .now, calendar: Calendar = .current) throws -> Double {
        let start = BudgetMonth.start(of: date, calendar: calendar)
        return try writer.read { db in
            var request = UsageEntry.filter(UsageEntry.Columns.recordedAt >= start)
            if let projectId { request = request.filter(Column("projectId") == projectId) }
            return try request.select(sum(UsageEntry.Columns.costUSD), as: Double?.self).fetchOne(db) ?? nil
        } ?? 0
    }

    public func weeklySpend(projectId: Int64? = nil, at date: Date = .now, calendar: Calendar = .current) throws -> Double {
        let start = BudgetWeek.start(of: date, calendar: calendar)
        return try writer.read { db in
            var request = UsageEntry.filter(UsageEntry.Columns.recordedAt >= start)
            if let projectId { request = request.filter(Column("projectId") == projectId) }
            return try request.select(sum(UsageEntry.Columns.costUSD), as: Double?.self).fetchOne(db) ?? nil
        } ?? 0
    }

    public func projectWeeklyBudgetStatus(projectId: Int64, at date: Date = .now, calendar: Calendar = .current) throws -> BudgetStatus {
        let settings = try project(id: projectId)?.settings ?? ProjectSettings()
        return BudgetStatus(
            budgetUSD: settings.weeklyBudgetUSD,
            spentUSD: try weeklySpend(projectId: projectId, at: date, calendar: calendar),
            allowedOverBudget: settings.allowsOverWeeklyBudget(at: date, calendar: calendar)
        )
    }

    @discardableResult
    public func allowOverWeeklyBudget(projectId: Int64, at date: Date = .now, calendar: Calendar = .current) throws -> ProjectSettings? {
        try writer.write { db in
            guard var project = try Project.fetchOne(db, id: projectId) else { return nil }
            project.settings.budgetOverrideWeek = BudgetWeek.key(for: date, calendar: calendar)
            try project.update(db)
            return project.settings
        }
    }

    public func projectBudgetStatus(projectId: Int64, at date: Date = .now, calendar: Calendar = .current) throws -> BudgetStatus {
        let settings = try project(id: projectId)?.settings ?? ProjectSettings()
        return BudgetStatus(
            budgetUSD: settings.monthlyBudgetUSD,
            spentUSD: try monthlySpend(projectId: projectId, at: date, calendar: calendar),
            allowedOverBudget: settings.allowsOverBudget(at: date, calendar: calendar)
        )
    }

    public func checkProjectBudget(projectId: Int64, at date: Date = .now, calendar: Calendar = .current) throws {
        guard let project = try self.project(id: projectId) else { return }
        if let budget = project.settings.weeklyBudgetUSD, budget > 0 {
            let status = try projectWeeklyBudgetStatus(projectId: projectId, at: date, calendar: calendar)
            if status.blocksNewWork {
                throw BudgetError.projectWeeklyBudgetReached(project: project.name, budgetUSD: budget, spentUSD: status.spentUSD)
            }
        }
        if let budget = project.settings.monthlyBudgetUSD, budget > 0 {
            let status = try projectBudgetStatus(projectId: projectId, at: date, calendar: calendar)
            if status.blocksNewWork {
                throw BudgetError.projectMonthlyBudgetReached(project: project.name, budgetUSD: budget, spentUSD: status.spentUSD)
            }
        }
    }

    @discardableResult
    public func allowOverBudget(projectId: Int64, at date: Date = .now, calendar: Calendar = .current) throws -> ProjectSettings? {
        try writer.write { db in
            guard var project = try Project.fetchOne(db, id: projectId) else { return nil }
            project.settings.budgetOverrideMonth = BudgetMonth.key(for: date, calendar: calendar)
            try project.update(db)
            return project.settings
        }
    }

    public func pendingWeeklyBudgetNotices(globalBudgetUSD: Double?, at date: Date = .now, calendar: Calendar = .current) throws -> [BudgetNotice] {
        let start = BudgetWeek.start(of: date, calendar: calendar)
        let week = BudgetWeek.title(for: date, calendar: calendar)
        return try writer.read { db in
            let sent = Set(try ChatRequest
                .filter(ChatRequest.Columns.createdAt >= start)
                .filter(Column("kind") == ChatRequestKind.notice.rawValue)
                .fetchAll(db)
                .map { BudgetNoticeKey(projectId: $0.projectId, title: $0.title) })
            let globalSent = Set(sent.map(\.title))
            let rows = try Row.fetchAll(db, sql: """
                SELECT projectId, SUM(costUSD) AS spent, MAX(recordedAt) AS lastRecordedAt
                FROM usage WHERE recordedAt >= ? GROUP BY projectId
                """, arguments: [start])
            var spendByProject: [Int64: Double] = [:]
            var latestProject: (id: Int64, at: Date)?
            for row in rows {
                let id: Int64 = row["projectId"]
                spendByProject[id] = row["spent"] ?? 0
                if let at: Date = row["lastRecordedAt"], latestProject.map({ at > $0.at }) ?? true { latestProject = (id, at) }
            }
            var notices: [BudgetNotice] = []
            for project in try Project.fetchAll(db) {
                guard let id = project.id, let budget = project.settings.weeklyBudgetUSD, budget > 0 else { continue }
                let spent = spendByProject[id] ?? 0
                for threshold in BudgetThreshold.crossed(spent: spent, budget: budget) {
                    let title = Self.weeklyNoticeTitle(threshold, global: false)
                    guard !sent.contains(BudgetNoticeKey(projectId: id, title: title)) else { continue }
                    notices.append(BudgetNotice(
                        scope: .project, threshold: threshold, projectId: id, title: title,
                        body: Self.noticeBody(threshold: threshold, subject: project.name, spent: spent, budget: budget, month: week, blocks: true)
                            .replacingOccurrences(of: "“Allow this month”", with: "“Allow this week”")
                    ))
                }
            }
            if let globalBudgetUSD, globalBudgetUSD > 0, let latestProject {
                let spent = spendByProject.values.reduce(0, +)
                for threshold in BudgetThreshold.crossed(spent: spent, budget: globalBudgetUSD) {
                    let title = Self.weeklyNoticeTitle(threshold, global: true)
                    guard !globalSent.contains(title) else { continue }
                    notices.append(BudgetNotice(
                        scope: .global, threshold: threshold, projectId: latestProject.id, title: title,
                        body: Self.noticeBody(threshold: threshold, subject: "All projects", spent: spent, budget: globalBudgetUSD, month: week, blocks: false)
                    ))
                }
            }
            return notices
        }
    }

    static func weeklyNoticeTitle(_ threshold: BudgetThreshold, global: Bool) -> String {
        switch (threshold, global) {
        case (.warning, false): "80% of the weekly budget used"
        case (.reached, false): "Weekly budget reached"
        case (.warning, true): "80% of your overall weekly budget used"
        case (.reached, true): "Overall weekly budget reached"
        }
    }

    public func pendingBudgetNotices(globalBudgetUSD: Double?, at date: Date = .now, calendar: Calendar = .current) throws -> [BudgetNotice] {
        let start = BudgetMonth.start(of: date, calendar: calendar)
        let month = BudgetMonth.title(for: date, calendar: calendar)
        return try writer.read { db in
            let sent = Set(try ChatRequest
                .filter(ChatRequest.Columns.createdAt >= start)
                .filter(Column("kind") == ChatRequestKind.notice.rawValue)
                .fetchAll(db)
                .map { BudgetNoticeKey(projectId: $0.projectId, title: $0.title) })
            let globalSent = Set(sent.map(\.title))
            var notices: [BudgetNotice] = []

            let spendRows = try Row.fetchAll(db, sql: """
                SELECT projectId, SUM(costUSD) AS spent, MAX(recordedAt) AS lastRecordedAt
                FROM usage WHERE recordedAt >= ? GROUP BY projectId
                """, arguments: [start])
            var spendByProject: [Int64: Double] = [:]
            var latestProject: (id: Int64, at: Date)?
            for row in spendRows {
                let id: Int64 = row["projectId"]
                spendByProject[id] = row["spent"] ?? 0
                if let at: Date = row["lastRecordedAt"], latestProject.map({ at > $0.at }) ?? true {
                    latestProject = (id, at)
                }
            }

            for project in try Project.fetchAll(db) {
                guard let id = project.id, let budget = project.settings.monthlyBudgetUSD, budget > 0 else { continue }
                let spent = spendByProject[id] ?? 0
                for threshold in BudgetThreshold.crossed(spent: spent, budget: budget) {
                    let title = Self.projectNoticeTitle(threshold)
                    guard !sent.contains(BudgetNoticeKey(projectId: id, title: title)) else { continue }
                    notices.append(BudgetNotice(
                        scope: .project, threshold: threshold, projectId: id, title: title,
                        body: Self.noticeBody(threshold: threshold, subject: project.name, spent: spent, budget: budget, month: month, blocks: true)
                    ))
                }
            }

            if let globalBudgetUSD, globalBudgetUSD > 0, let latestProject {
                let spent = spendByProject.values.reduce(0, +)
                for threshold in BudgetThreshold.crossed(spent: spent, budget: globalBudgetUSD) {
                    let title = Self.globalNoticeTitle(threshold)
                    guard !globalSent.contains(title) else { continue }
                    notices.append(BudgetNotice(
                        scope: .global, threshold: threshold, projectId: latestProject.id, title: title,
                        body: Self.noticeBody(threshold: threshold, subject: "All projects", spent: spent, budget: globalBudgetUSD, month: month, blocks: false)
                    ))
                }
            }
            return notices
        }
    }

    @discardableResult
    public func recordBudgetNotices(globalBudgetUSD: Double?, globalWeeklyBudgetUSD: Double? = nil, at date: Date = .now, calendar: Calendar = .current) throws -> [ChatRequest] {
        let notices = try pendingWeeklyBudgetNotices(globalBudgetUSD: globalWeeklyBudgetUSD, at: date, calendar: calendar)
            + pendingBudgetNotices(globalBudgetUSD: globalBudgetUSD, at: date, calendar: calendar)
        return try notices.map { notice in
            try createChatRequest(ChatRequest(projectId: notice.projectId, kind: .notice, title: notice.title, body: notice.body, createdAt: date))
        }
    }

    static func projectNoticeTitle(_ threshold: BudgetThreshold) -> String {
        switch threshold {
        case .warning: "80% of the monthly budget used"
        case .reached: "Monthly budget reached"
        }
    }

    static func globalNoticeTitle(_ threshold: BudgetThreshold) -> String {
        switch threshold {
        case .warning: "80% of your overall monthly budget used"
        case .reached: "Overall monthly budget reached"
        }
    }

    static func noticeBody(threshold: BudgetThreshold, subject: String, spent: Double, budget: Double, month: String, blocks: Bool) -> String {
        let amounts = "\(subject) has spent \(spent.formatted(.currency(code: "USD"))) of \(budget.formatted(.currency(code: "USD"))) in \(month)."
        switch (threshold, blocks) {
        case (.warning, _):
            return amounts + " Check Usage to see where it went."
        case (.reached, true):
            return amounts + " New runs and agent turns in this project are paused until you raise the budget or choose “Allow this month” in Usage."
        case (.reached, false):
            return amounts + " Nothing is blocked; raise the overall budget in Usage if this is expected."
        }
    }
}

private struct BudgetNoticeKey: Hashable {
    let projectId: Int64
    let title: String
}
