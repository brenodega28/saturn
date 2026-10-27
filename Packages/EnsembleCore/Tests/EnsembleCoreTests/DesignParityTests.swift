import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct WeeklyBudgetTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @Test func aWeeklyBudgetBlocksNewWorkUntilAllowed() throws {
        let database = try AppDatabase.inMemory()
        var project = try database.openProject(at: FileManager.default.temporaryDirectory.appending(path: "weekly-\(UUID().uuidString)"))
        let id = try #require(project.id)
        var settings = ProjectSettings()
        settings.weeklyBudgetUSD = 10
        settings.monthlyBudgetUSD = 100
        try database.updateSettings(settings, forProject: id)
        project = try #require(try database.project(id: id))
        try database.record(UsageEntry(projectId: id, model: "sonnet", costUSD: 6, recordedAt: date("2026-10-19T09:00:00Z")))
        try database.record(UsageEntry(projectId: id, model: "sonnet", costUSD: 9, recordedAt: date("2026-10-27T09:00:00Z")))
        try database.record(UsageEntry(projectId: id, model: "sonnet", costUSD: 2, recordedAt: date("2026-10-28T09:00:00Z")))
        let now = date("2026-10-28T12:00:00Z")

        #expect(try database.weeklySpend(projectId: id, at: now, calendar: calendar) == 11)
        #expect(throws: BudgetError.projectWeeklyBudgetReached(project: project.name, budgetUSD: 10, spentUSD: 11)) {
            try database.checkProjectBudget(projectId: id, at: now, calendar: calendar)
        }
        let notices = try database.pendingWeeklyBudgetNotices(globalBudgetUSD: 50, at: now, calendar: calendar)
        #expect(notices.map(\.title) == ["80% of the weekly budget used", "Weekly budget reached"])
        #expect(notices.last?.body.contains("“Allow this week”") == true)

        try database.allowOverWeeklyBudget(projectId: id, at: now, calendar: calendar)
        try database.checkProjectBudget(projectId: id, at: now, calendar: calendar)
        #expect(try database.projectWeeklyBudgetStatus(projectId: id, at: date("2026-11-03T12:00:00Z"), calendar: calendar).allowedOverBudget == false)
    }
}
