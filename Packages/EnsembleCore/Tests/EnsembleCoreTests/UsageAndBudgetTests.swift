import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct UsageReportTests {
    struct Fixture {
        let database: AppDatabase
        let shop: Project
        let docs: Project
        let run: Run
        let calendar: Calendar
        let now: Date
    }

    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func makeFixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let calendar = Self.calendar()
        let now = Self.date("2026-10-22T12:00:00Z")
        let shop = try database.openProject(at: URL(fileURLWithPath: "/tmp/shopfront"))
        let docs = try database.openProject(at: URL(fileURLWithPath: "/tmp/docs-site"))
        let task = try database.insert(Chat(projectId: shop.id!, title: "Refunds", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now))
        let run = try database.insert(Run(projectId: shop.id!, taskId: task.id!, workflow: "feature-delivery", status: .succeeded, startedAt: now, title: "Refunds v2"), state: RunEngineState())
        let lead = try database.insert(Agent(projectId: shop.id!, runId: run.id, role: "tech-lead", name: "Tech Lead", status: .idle, createdAt: now, updatedAt: now))
        let dev = try database.insert(Agent(projectId: shop.id!, runId: run.id, role: "claude-code", name: "Dev 1", status: .idle, createdAt: now, updatedAt: now))
        let solo = try database.insert(Agent(projectId: docs.id!, role: "claude-code", name: "Solo", status: .idle, createdAt: now, updatedAt: now))

        func usage(_ project: Project, run: Run? = nil, agent: Agent?, model: String, cost: Double, at date: String, tokens: Int = 100) throws {
            try database.record(UsageEntry(
                projectId: project.id!, runId: run?.id, agentId: agent?.id, model: model,
                inputTokens: tokens, outputTokens: tokens / 2, costUSD: cost, recordedAt: Self.date(date)
            ))
        }
        try usage(shop, run: run, agent: lead, model: "claude-opus-5-5", cost: 3.00, at: "2026-10-21T09:00:00Z")
        try usage(shop, run: run, agent: dev, model: "claude-sonnet-5-5", cost: 1.50, at: "2026-10-22T09:00:00Z")
        try usage(shop, run: run, agent: dev, model: "claude-sonnet-5-5", cost: 0.50, at: "2026-10-05T09:00:00Z")
        try usage(docs, agent: solo, model: "claude-sonnet-5-5", cost: 2.00, at: "2026-10-20T09:00:00Z")
        try usage(docs, agent: nil, model: "claude-haiku-5", cost: 4.00, at: "2026-09-15T09:00:00Z")
        return Fixture(database: database, shop: shop, docs: docs, run: run, calendar: calendar, now: now)
    }

    @Test func totalsCoverWeekMonthAndAllTime() throws {
        let fixture = try makeFixture()
        let totals = try fixture.database.usageTotals(at: fixture.now, calendar: fixture.calendar)
        #expect(abs(totals.weekUSD - 6.50) < 0.0001)
        #expect(abs(totals.monthUSD - 7.00) < 0.0001)
        #expect(abs(totals.allTimeUSD - 11.00) < 0.0001)
    }

    @Test func resetPointRestartsWeekAndMonthButNotAllTime() throws {
        let fixture = try makeFixture()
        let reset = Self.date("2026-10-21T12:00:00Z")
        let totals = try fixture.database.usageTotals(at: fixture.now, calendar: fixture.calendar, countingSince: reset)
        #expect(abs(totals.weekUSD - 1.50) < 0.0001)
        #expect(abs(totals.monthUSD - 1.50) < 0.0001)
        #expect(abs(totals.allTimeUSD - 11.00) < 0.0001)

        let report = try fixture.database.usageReport(period: .month, at: fixture.now, calendar: fixture.calendar, totalsCountingSince: reset)
        #expect(abs(report.totals.monthUSD - 1.50) < 0.0001)
        #expect(report.byProject.map(\.costUSD) == [5.00, 2.00])
        #expect(report.expensiveTurns.count == 4)
    }

    @Test func resetPointBeforeThePeriodLeavesTotalsUnchanged() throws {
        let fixture = try makeFixture()
        let reset = Self.date("2026-10-10T00:00:00Z")
        let totals = try fixture.database.usageTotals(at: fixture.now, calendar: fixture.calendar, countingSince: reset)
        #expect(abs(totals.weekUSD - 6.50) < 0.0001)
        #expect(abs(totals.monthUSD - 6.50) < 0.0001)
        #expect(abs(totals.allTimeUSD - 11.00) < 0.0001)

        let monthStart = UsagePeriod.month.start(at: fixture.now, calendar: fixture.calendar)
        #expect(UsagePeriod.month.displayedStart(at: fixture.now, calendar: fixture.calendar, countingSince: Self.date("2026-01-01T00:00:00Z")) == monthStart)
        #expect(UsagePeriod.allTime.displayedStart(at: fixture.now, calendar: fixture.calendar, countingSince: reset) == nil)
    }

    @Test func breakdownsGroupByProjectRunRoleAndModel() throws {
        let fixture = try makeFixture()
        let report = try fixture.database.usageReport(period: .month, at: fixture.now, calendar: fixture.calendar)

        #expect(report.byProject.map(\.title) == ["shopfront", "docs-site"])
        #expect(report.byProject.map(\.costUSD) == [5.00, 2.00])
        #expect(report.byProject.map(\.turns) == [3, 1])
        #expect(report.byProject.first?.tokens == 450)

        #expect(report.byRun.map(\.title) == ["Refunds v2", "Outside runs"])
        #expect(report.byRun.map(\.costUSD) == [5.00, 2.00])
        #expect(report.byRun.first?.detail == "shopfront · feature-delivery")

        #expect(report.byRole.map(\.title) == ["claude-code", "tech-lead"])
        #expect(report.byRole.map(\.costUSD) == [4.00, 3.00])
        #expect(report.byModel.map(\.title) == ["claude-sonnet-5-5", "claude-opus-5-5"])
        #expect(report.byModel.map(\.costUSD) == [4.00, 3.00])

        #expect(report.expensiveTurns.map(\.costUSD) == [3.00, 2.00, 1.50, 0.50])
        #expect(report.expensiveTurns.first?.agentName == "Tech Lead")
        #expect(report.expensiveTurns.first?.runTitle == "Refunds v2")
        #expect(report.expensiveTurns.first?.role == "tech-lead")
    }

    @Test func allTimeIncludesDeletedAgentsAndCanFilterByProject() throws {
        let fixture = try makeFixture()
        let report = try fixture.database.usageReport(period: .allTime, at: fixture.now, calendar: fixture.calendar)
        #expect(report.byRole.contains { $0.key == "role-none" && $0.costUSD == 4.00 })
        #expect(report.byModel.first?.title == "claude-sonnet-5-5")

        let docsOnly = try fixture.database.usageReport(period: .allTime, projectId: fixture.docs.id, at: fixture.now, calendar: fixture.calendar)
        #expect(docsOnly.byProject.map(\.title) == ["docs-site"])
        #expect(docsOnly.byProject.first?.costUSD == 6.00)
        #expect(docsOnly.expensiveTurns.map(\.costUSD) == [4.00, 2.00])

        let week = try fixture.database.usageReport(period: .week, at: fixture.now, calendar: fixture.calendar)
        #expect(week.byProject.map(\.costUSD) == [4.50, 2.00])
    }
}

@Suite struct BudgetTests {
    let calendar = UsageReportTests.calendar()

    func date(_ text: String) -> Date { UsageReportTests.date(text) }

    func makeProject(_ database: AppDatabase, budget: Double?) throws -> Project {
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shopfront"))
        try database.updateSettings(ProjectSettings(monthlyBudgetUSD: budget), forProject: project.id!)
        return try #require(try database.project(id: project.id!))
    }

    func spend(_ database: AppDatabase, _ project: Project, _ cost: Double, at: String) throws {
        try database.record(UsageEntry(projectId: project.id!, model: "claude-sonnet-5-5", costUSD: cost, recordedAt: date(at)))
    }

    @Test func thresholdsAreCrossedAtEightyAndOneHundredPercent() {
        #expect(BudgetThreshold.crossed(spent: 79.99, budget: 100) == [])
        #expect(BudgetThreshold.crossed(spent: 80, budget: 100) == [.warning])
        #expect(BudgetThreshold.crossed(spent: 100, budget: 100) == [.warning, .reached])
        #expect(BudgetThreshold.crossed(spent: 500, budget: nil) == [])
        #expect(BudgetThreshold.crossed(spent: 500, budget: 0) == [])
        #expect(BudgetMonth.key(for: date("2026-10-31T23:59:00Z"), calendar: calendar) == "2026-10")
    }

    @Test func noticesAreCreatedOncePerThresholdPerMonth() throws {
        let database = try AppDatabase.inMemory()
        let project = try makeProject(database, budget: 10)
        let now = date("2026-10-22T12:00:00Z")

        try spend(database, project, 7.9, at: "2026-10-02T10:00:00Z")
        #expect(try database.recordBudgetNotices(globalBudgetUSD: nil, at: now, calendar: calendar).isEmpty)

        try spend(database, project, 0.2, at: "2026-10-03T10:00:00Z")
        let warning = try database.recordBudgetNotices(globalBudgetUSD: nil, at: now, calendar: calendar)
        #expect(warning.map(\.title) == ["80% of the monthly budget used"])
        #expect(warning.first?.kind == .notice)
        #expect(warning.first?.projectId == project.id)
        #expect(try database.recordBudgetNotices(globalBudgetUSD: nil, at: now, calendar: calendar).isEmpty)

        try database.resolveChatRequest(id: warning[0].id!, status: .dismissed)
        try spend(database, project, 2, at: "2026-10-04T10:00:00Z")
        let reached = try database.recordBudgetNotices(globalBudgetUSD: nil, at: now, calendar: calendar)
        #expect(reached.map(\.title) == ["Monthly budget reached"])
        #expect(reached.first?.body.contains("Allow this month") == true)
        #expect(try database.recordBudgetNotices(globalBudgetUSD: nil, at: now, calendar: calendar).isEmpty)

        let november = date("2026-11-02T12:00:00Z")
        #expect(try database.recordBudgetNotices(globalBudgetUSD: nil, at: november, calendar: calendar).isEmpty)
        try spend(database, project, 9, at: "2026-11-02T10:00:00Z")
        #expect(try database.recordBudgetNotices(globalBudgetUSD: nil, at: november, calendar: calendar).map(\.title) == ["80% of the monthly budget used"])
    }

    @Test func globalBudgetNoticesAreRaisedOnceAcrossProjects() throws {
        let database = try AppDatabase.inMemory()
        let shop = try makeProject(database, budget: nil)
        let docs = try database.openProject(at: URL(fileURLWithPath: "/tmp/docs"))
        let now = date("2026-10-22T12:00:00Z")
        try spend(database, shop, 30, at: "2026-10-02T10:00:00Z")
        try spend(database, docs, 21, at: "2026-10-05T10:00:00Z")

        let notices = try database.recordBudgetNotices(globalBudgetUSD: 50, at: now, calendar: calendar)
        #expect(notices.map(\.title) == ["80% of your overall monthly budget used", "Overall monthly budget reached"])
        #expect(notices.allSatisfy { $0.projectId == docs.id })
        #expect(try database.recordBudgetNotices(globalBudgetUSD: 50, at: now, calendar: calendar).isEmpty)
    }

    @Test func reachedProjectBudgetBlocksNewWorkUntilAllowedOrRaised() throws {
        let database = try AppDatabase.inMemory()
        let project = try makeProject(database, budget: 5)
        let now = date("2026-10-22T12:00:00Z")
        try database.checkProjectBudget(projectId: project.id!, at: now, calendar: calendar)

        try spend(database, project, 5, at: "2026-10-20T10:00:00Z")
        #expect(throws: BudgetError.self) { try database.checkProjectBudget(projectId: project.id!, at: now, calendar: calendar) }
        #expect(try database.projectBudgetStatus(projectId: project.id!, at: now, calendar: calendar).blocksNewWork)

        try database.allowOverBudget(projectId: project.id!, at: now, calendar: calendar)
        try database.checkProjectBudget(projectId: project.id!, at: now, calendar: calendar)
        #expect(try database.project(id: project.id!)?.settings.budgetOverrideMonth == "2026-10")

        let november = date("2026-11-10T12:00:00Z")
        try spend(database, project, 6, at: "2026-11-01T10:00:00Z")
        #expect(throws: BudgetError.self) { try database.checkProjectBudget(projectId: project.id!, at: november, calendar: calendar) }

        var settings = try #require(try database.project(id: project.id!)).settings
        settings.monthlyBudgetUSD = 20
        try database.updateSettings(settings, forProject: project.id!)
        try database.checkProjectBudget(projectId: project.id!, at: november, calendar: calendar)
    }

    @Test func budgetsKeepCountingRealMonthlySpendAfterAUsageReset() throws {
        let database = try AppDatabase.inMemory()
        let project = try makeProject(database, budget: 10)
        let now = date("2026-10-22T12:00:00Z")
        try spend(database, project, 9, at: "2026-10-02T10:00:00Z")
        try spend(database, project, 1, at: "2026-10-21T10:00:00Z")

        let totals = try database.usageTotals(at: now, calendar: calendar, countingSince: date("2026-10-20T00:00:00Z"))
        #expect(abs(totals.monthUSD - 1) < 0.0001)

        #expect(abs(try database.monthlySpend(at: now, calendar: calendar) - 10) < 0.0001)
        let status = try database.projectBudgetStatus(projectId: project.id!, at: now, calendar: calendar)
        #expect(abs(status.spentUSD - 10) < 0.0001)
        #expect(status.blocksNewWork)
        #expect(throws: BudgetError.self) { try database.checkProjectBudget(projectId: project.id!, at: now, calendar: calendar) }
        let notices = try database.recordBudgetNotices(globalBudgetUSD: nil, at: now, calendar: calendar)
        #expect(notices.map(\.title) == ["80% of the monthly budget used", "Monthly budget reached"])
    }

    @MainActor
    @Test func agentTurnsAreRefusedWhenTheProjectBudgetIsReached() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try harness.database.updateSettings(ProjectSettings(monthlyBudgetUSD: 1), forProject: harness.project.id!)
        try harness.database.record(UsageEntry(projectId: harness.project.id!, model: "claude-fake-1", costUSD: 1.5, recordedAt: .now))

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .failed }
        #expect(session.agent.lastError?.contains("monthly budget") == true)
        #expect(harness.launches().isEmpty)

        try harness.database.allowOverBudget(projectId: harness.project.id!)
        session.resume()
        try await waitUntil { session.agent.status == .idle }
        #expect(harness.launches().count == 1)
    }
}
