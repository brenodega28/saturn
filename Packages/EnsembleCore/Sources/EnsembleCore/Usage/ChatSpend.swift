import Foundation
import GRDB

public enum ChatSpendWarning {
    public static let milestonesUSD: [Double] = [10, 25, 50, 75, 100]

    public static var milestoneList: String {
        let labels = milestonesUSD.map(label)
        return labels.dropLast().joined(separator: ", ") + " and " + (labels.last ?? "")
    }

    public static func title(for milestone: Double) -> String {
        "This chat has passed " + label(milestone)
    }

    private static func label(_ amount: Double) -> String {
        String(format: "$%.0f", amount)
    }

    static func body(spent: Double) -> String {
        String(format: "Its Lead, runs and agents have spent $%.2f so far. Nothing is paused; this is only a heads-up.", spent)
    }

    static func highestMilestone(reachedBy spent: Double) -> Double? {
        milestonesUSD.last { spent >= $0 - 0.000_001 }
    }
}

extension AppDatabase {
    public func monthlySpend(projectId: Int64? = nil, at date: Date = .now, calendar: Calendar = .current) throws -> Double {
        try spend(projectId: projectId, since: calendar.dateInterval(of: .month, for: date)?.start ?? date)
    }

    public func weeklySpend(projectId: Int64? = nil, at date: Date = .now, calendar: Calendar = .current) throws -> Double {
        try spend(projectId: projectId, since: calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date)
    }

    private func spend(projectId: Int64?, since start: Date) throws -> Double {
        try writer.read { db in
            var request = UsageEntry.filter(UsageEntry.Columns.recordedAt >= start)
            if let projectId { request = request.filter(Column("projectId") == projectId) }
            return try request.select(sum(UsageEntry.Columns.costUSD), as: Double?.self).fetchOne(db) ?? nil
        } ?? 0
    }

    @discardableResult
    public func recordChatSpendWarnings(at date: Date = .now) throws -> [ChatRequest] {
        try writer.write { db in
            var posted: [ChatRequest] = []
            for (chatId, spent) in try Self.openChatSpend(db) {
                guard let milestone = ChatSpendWarning.highestMilestone(reachedBy: spent),
                      let projectId = try Int64.fetchOne(db, sql: "SELECT projectId FROM task WHERE id = ?", arguments: [chatId])
                else { continue }
                let warned = Set(try String.fetchAll(db, sql: """
                    SELECT title FROM chatRequest WHERE taskId = ? AND kind = ?
                    """, arguments: [chatId, ChatRequestKind.notice.rawValue]))
                let alreadyWarned = ChatSpendWarning.milestonesUSD
                    .filter { $0 >= milestone }
                    .contains { warned.contains(ChatSpendWarning.title(for: $0)) }
                guard !alreadyWarned else { continue }
                posted.append(try ChatRequest.insertAttached(ChatRequest(
                    projectId: projectId, taskId: chatId, kind: .notice,
                    title: ChatSpendWarning.title(for: milestone), body: ChatSpendWarning.body(spent: spent), createdAt: date
                ), db))
            }
            return posted
        }
    }

    private static func openChatSpend(_ db: Database) throws -> [Int64: Double] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id AS chatId, SUM(u.costUSD) AS spent
            FROM usage u
            LEFT JOIN run r ON r.id = u.runId
            LEFT JOIN agent a ON a.id = u.agentId
            LEFT JOIN run ar ON ar.id = a.runId
            JOIN task t ON t.id = COALESCE(r.taskId, a.taskId, ar.taskId)
            WHERE t.closedAt IS NULL
            GROUP BY t.id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["chatId"], $0["spent"] ?? 0) })
    }
}
