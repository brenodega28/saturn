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

@Suite struct ChatSpendWarningTests {
    let now = UsageReportTests.date("2026-10-22T12:00:00Z")

    struct Fixture {
        let database: AppDatabase
        let project: Project
        let chat: Chat
        let lead: Agent
        let run: Run
        let builder: Agent
    }

    func makeFixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shopfront"))
        let chat = try database.insert(Chat(projectId: project.id!, title: "Refunds", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now))
        let lead = try database.insert(Agent(projectId: project.id!, role: "lead", name: "Lead", status: .idle, taskId: chat.id, createdAt: now, updatedAt: now))
        let run = try database.insert(Run(projectId: project.id!, taskId: chat.id!, workflow: "feature-delivery", status: .running, startedAt: now), state: RunEngineState())
        let builder = try database.insert(Agent(projectId: project.id!, runId: run.id, role: "builder", name: "Dev 1", status: .idle, createdAt: now, updatedAt: now))
        return Fixture(database: database, project: project, chat: chat, lead: lead, run: run, builder: builder)
    }

    func spend(_ fixture: Fixture, _ cost: Double, agent: Agent? = nil, run: Run? = nil) throws {
        try fixture.database.record(UsageEntry(
            projectId: fixture.project.id!, runId: run?.id, agentId: agent?.id, model: "claude-sonnet-5-5", costUSD: cost, recordedAt: now
        ))
    }

    @Test func eachMilestoneIsAnnouncedOnceInTheChat() throws {
        let fixture = try makeFixture()
        let database = fixture.database

        try spend(fixture, 9.99, agent: fixture.lead)
        #expect(try database.recordChatSpendWarnings(at: now).isEmpty)

        try spend(fixture, 0.01, agent: fixture.builder)
        let first = try database.recordChatSpendWarnings(at: now)
        #expect(first.map(\.title) == ["This chat has passed $10"])
        #expect(first.first?.kind == .notice)
        #expect(first.first?.taskId == fixture.chat.id)
        #expect(first.first?.body.contains("$10.00 so far") == true)
        #expect(try database.recordChatSpendWarnings(at: now).isEmpty)

        try database.resolveChatRequest(id: first[0].id!, status: .dismissed)
        #expect(try database.recordChatSpendWarnings(at: now).isEmpty)

        try spend(fixture, 15, agent: fixture.builder, run: fixture.run)
        #expect(try database.recordChatSpendWarnings(at: now).map(\.title) == ["This chat has passed $25"])

        try spend(fixture, 80, run: fixture.run)
        #expect(try database.recordChatSpendWarnings(at: now).map(\.title) == ["This chat has passed $100"])

        try spend(fixture, 500, agent: fixture.lead)
        #expect(try database.recordChatSpendWarnings(at: now).isEmpty)
        #expect(try database.chatRequests(taskId: fixture.chat.id!).map(\.title) == [
            "This chat has passed $10", "This chat has passed $25", "This chat has passed $100",
        ])
    }

    @Test func spendIsCountedPerChatAndClosedChatsStayQuiet() throws {
        let fixture = try makeFixture()
        let database = fixture.database
        let other = try database.insert(Chat(projectId: fixture.project.id!, title: "Docs", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now))
        let otherLead = try database.insert(Agent(projectId: fixture.project.id!, role: "lead", name: "Lead 2", status: .idle, taskId: other.id, createdAt: now, updatedAt: now))
        let closed = try database.insert(Chat(projectId: fixture.project.id!, title: "Old", body: "", source: .chat, status: .done, closedAt: now, createdAt: now, updatedAt: now))
        let closedLead = try database.insert(Agent(projectId: fixture.project.id!, role: "lead", name: "Lead 3", status: .idle, taskId: closed.id, createdAt: now, updatedAt: now))

        try spend(fixture, 6, agent: fixture.lead)
        try spend(fixture, 6, agent: otherLead)
        try spend(fixture, 30, agent: closedLead)
        try spend(fixture, 30)
        #expect(try database.recordChatSpendWarnings(at: now).isEmpty)

        try spend(fixture, 5, agent: otherLead)
        let warnings = try database.recordChatSpendWarnings(at: now)
        #expect(warnings.map(\.taskId) == [other.id])
        #expect(warnings.map(\.title) == ["This chat has passed $10"])
    }

    @Test func weeklyAndMonthlySpendStillCountRealSpendAfterAUsageReset() throws {
        let database = try AppDatabase.inMemory()
        let calendar = UsageReportTests.calendar()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shopfront"))
        for (cost, at) in [(6.0, "2026-10-19T09:00:00Z"), (9, "2026-10-02T09:00:00Z"), (2, "2026-10-21T09:00:00Z")] {
            try database.record(UsageEntry(projectId: project.id!, model: "claude-sonnet-5-5", costUSD: cost, recordedAt: UsageReportTests.date(at)))
        }
        let totals = try database.usageTotals(at: now, calendar: calendar, countingSince: UsageReportTests.date("2026-10-20T00:00:00Z"))
        #expect(abs(totals.monthUSD - 2) < 0.0001)
        #expect(abs(try database.monthlySpend(at: now, calendar: calendar) - 17) < 0.0001)
        #expect(abs(try database.weeklySpend(projectId: project.id!, at: now, calendar: calendar) - 8) < 0.0001)
    }

    @Test func legacyBudgetHoldsBecomeRetryableFailures() throws {
        let fixture = try makeFixture()
        let database = fixture.database
        let request = try database.createChatRequest(ChatRequest(
            projectId: fixture.project.id!, runId: fixture.run.id, kind: .budget, title: "Run reached its budget", createdAt: now
        ))
        let held = RunEngineState(
            cursor: RunCursor(stepId: "build", iteration: 1),
            hold: RunHold(reason: .stepFailed, stepId: "build", requestId: request.id, message: "Raise the budget")
        )
        let legacy = try RunEngineState.encode(held).replacingOccurrences(of: "step_failed", with: "run_budget")
        #expect(legacy.contains("run_budget"))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE run SET engineState = ? WHERE id = ?", arguments: [legacy, fixture.run.id])
            try AppDatabase.releaseBudgetHolds(db)
        }

        let hold = try #require(try database.engineState(runId: fixture.run.id!).hold)
        #expect(hold.reason == .stepFailed)
        #expect(hold.message.contains("Budget limits were removed"))
        #expect(try database.chatRequest(id: request.id!)?.kind == .failure)
    }

    @MainActor
    @Test func agentTurnsRunNoMatterHowMuchTheProjectHasSpent() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try harness.database.record(UsageEntry(projectId: harness.project.id!, model: "claude-fake-1", costUSD: 5_000, recordedAt: .now))

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        #expect(harness.launches().count == 1)
    }
}
