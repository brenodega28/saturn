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

@MainActor
@Suite(.serialized) struct AgentControlTests {
    @Test func pauseAllPausesWorkingAndQueuedAgents() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        var settings = ProjectSettings()
        settings.maxConcurrentAgents = 1
        try harness.database.updateSettings(settings, forProject: try #require(harness.project.id))
        let first = try await harness.spawn("Dev 1")
        let second = try await harness.spawn("Dev 2")
        try await waitUntil { first.isRunning && second.isQueued }

        #expect(try harness.runtime.pauseAll(inProject: try #require(harness.project.id)) == 2)
        try await waitUntil { first.agent.status == .paused && second.agent.status == .paused }
        #expect(!second.isQueued)
    }

    @Test func approvalStepsCanRemindDaily() async throws {
        let h = try WorkflowHarness.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "r", name: "R", steps: [
            WorkflowStep(id: "approve", type: .approval, remindDaily: true, routes: [StepOutcome.approved: WorkflowRoute(to: "end")]),
        ])
        let id = try await h.start(workflow)
        let opened = try #require(try h.database.inboxItems(runId: id).first).createdAt

        #expect(try h.engine.postApprovalReminders(now: opened.addingTimeInterval(3600)).isEmpty)
        let first = try h.engine.postApprovalReminders(now: opened.addingTimeInterval(90_000))
        #expect(first.map(\.title) == ["Still waiting for you: Refunds v2"])
        #expect(first.first?.body.hasSuffix("has waited 1 day for your approval.") == true)
        #expect(try h.engine.postApprovalReminders(now: opened.addingTimeInterval(100_000)).isEmpty)
        #expect(try h.engine.postApprovalReminders(now: opened.addingTimeInterval(180_000)).count == 1)
    }

    @Test func spawnStepsCanHandTasksToPinnedAgents() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        let projectID = try #require(setup.project.id)
        let role = try #require(setup.config.role("claude-code"))
        let spawned = try await setup.harness.runtime.spawn(
            in: setup.project, role: role, count: 1, config: setup.config, git: setup.harness.repo.git, pinned: true, name: "Veteran"
        )
        let pinned = try #require(spawned.first)
        var feature = try #require(setup.config.workflow("feature-delivery"))
        let build = try #require(feature.steps.firstIndex { $0.id == "build" })
        feature.steps[build].reusePinned = true
        let task = try setup.harness.database.insert(ProjectTask(projectId: projectID, title: "Add alpha and beta", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now))
        let run = try setup.engine.start(task: task, workflow: feature, project: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let veteran = try #require(try setup.harness.database.agent(id: pinned.id))
        #expect(veteran.runId == run.id)
        #expect(veteran.planTaskId != nil)
        #expect(veteran.isPinned)
        #expect(veteran.branch?.hasPrefix("crew/veteran/") == true)
        let builders = try setup.harness.database.agents(inProject: projectID).filter { $0.runId == run.id && $0.planTaskId != nil }
        #expect(builders.count == 2)
    }
}
