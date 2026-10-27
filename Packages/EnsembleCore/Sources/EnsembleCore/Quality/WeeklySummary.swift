import Foundation
import GRDB

public enum WeeklySummary {
    public static func title(project: Project, weekStart: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return "Week of \(weekStart.formatted(style)) in \(project.name)"
    }

    @discardableResult
    public static func postIfDue(for project: Project, database: AppDatabase, now: Date = .now, calendar: Calendar = .current) throws -> InboxItem? {
        guard let projectId = project.id,
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) else { return nil }
        let title = title(project: project, weekStart: lastWeek, calendar: calendar)
        let posted = try database.writer.read { db in
            try InboxItem.filter(Column("projectId") == projectId).filter(Column("title") == title).fetchCount(db) > 0
        }
        guard !posted else { return nil }
        let report = try database.qualityReport(projectIds: [projectId], weeks: 2, now: now, calendar: calendar)
        guard let week = report.weeks.first, week.start == lastWeek, week.finishedRuns > 0 || week.checkRuns > 0 || week.rulesAdded > 0 else { return nil }
        return try database.createInboxItem(InboxItem(projectId: projectId, kind: .notice, title: title, body: body(for: week), createdAt: now))
    }

    public static func body(for week: QualityWeek) -> String {
        var lines: [String] = []
        lines.append("\(week.approvedChanges) change\(week.approvedChanges == 1 ? "" : "s") approved" + (week.medianChangeSize.map { ", median \($0) lines" } ?? "") + ".")
        if let minutes = week.medianApprovalMinutes {
            lines.append("Median time to approve: \(Self.duration(minutes)).")
        }
        if let rate = week.checkFailureRate {
            var line = "Checks failed the first time in \(Int((rate * 100).rounded()))% of check steps"
            if let check = week.mostFailingCheck { line += "; \(check) failed most" }
            lines.append(line + ".")
        }
        if let rework = week.reworkRate {
            lines.append("\(Int((rework * 100).rounded()))% of finished runs needed rework from you.")
        }
        if week.duplicationWarnings + week.complexityWarnings > 0 {
            lines.append("Gates flagged \(week.duplicationWarnings) duplication and \(week.complexityWarnings) complexity warning\(week.complexityWarnings == 1 ? "" : "s").")
        }
        if let cost = week.costPerApprovedChange {
            lines.append("Cost per approved change: \(cost.formatted(.currency(code: "USD"))).")
        }
        lines.append(week.rulesAdded == 0 ? "No new rules were encoded from your corrections." : "\(week.rulesAdded) correction\(week.rulesAdded == 1 ? " was" : "s were") encoded as rules.")
        return lines.joined(separator: "\n")
    }

    static func duration(_ minutes: Double) -> String {
        if minutes < 120 { return "\(Int(minutes.rounded())) min" }
        if minutes < 60 * 48 { return (minutes / 60).formatted(.number.precision(.fractionLength(1))) + " h" }
        return (minutes / 1440).formatted(.number.precision(.fractionLength(1))) + " days"
    }
}
