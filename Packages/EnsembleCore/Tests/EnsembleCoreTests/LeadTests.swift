import Foundation
import GRDB
import Testing
@testable import EnsembleCore

struct PlanEditingTests {
    static let plan = Plan(summary: "Export orders", tasks: [
        PlanTask(id: "a", title: "Endpoint", skills: ["django"]),
        PlanTask(id: "b", title: "Streaming", skills: ["django"]),
        PlanTask(id: "c", title: "Button", skills: ["react"]),
    ])

    @Test func movesTasksUpAndDownWithinBounds() {
        var plan = Self.plan
        plan.moveTask(id: "b", by: -1)
        #expect(plan.tasks.map(\.id) == ["b", "a", "c"])
        plan.moveTask(id: "b", by: -1)
        #expect(plan.tasks.map(\.id) == ["b", "a", "c"])
        plan.moveTask(id: "a", by: 1)
        #expect(plan.tasks.map(\.id) == ["b", "c", "a"])
        plan.moveTask(id: "a", by: 1)
        plan.moveTask(id: "missing", by: 1)
        #expect(plan.tasks.map(\.id) == ["b", "c", "a"])
    }

    @Test func changesSkills() {
        var plan = Self.plan
        plan.setSkills(["react", "design-tokens"], forTask: "c")
        #expect(plan.tasks.map(\.skills) == [["django"], ["django"], ["react", "design-tokens"]])
        #expect(plan.tasks.allSatisfy { $0.agent == .builder })
    }

    @Test func removesTasksAndDescribesSize() {
        var plan = Self.plan
        #expect(plan.sizeDescription == "3 tasks")
        plan.removeTask(id: "b")
        plan.removeTask(id: "c")
        #expect(plan.tasks.map(\.id) == ["a"])
        #expect(plan.sizeDescription == "1 task")
    }

    @Test func decodesAnOldPlanThatStillHasACount() throws {
        let json = #"{"summary":"Export orders","tasks":[{"id":"b","title":"Streaming","role":"django","count":3,"files":["api/"]}]}"#
        let plan = try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        #expect(plan.tasks == [PlanTask(id: "b", title: "Streaming", agent: .builder, files: ["api/"])])
        let reencoded = try #require(String(data: try JSONEncoder().encode(plan), encoding: .utf8))
        #expect(!reencoded.contains("count"))
    }
}

struct LeadRequestTests {
    @Test func titleUsesTheFirstNonEmptyLine() {
        #expect(LeadRequest.title(for: "\n  Add refunds  \nMore detail") == "Add refunds")
    }

    @Test func longTitlesBreakAtAWord() {
        let text = String(repeating: "refund ", count: 20)
        let title = LeadRequest.title(for: text)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= LeadRequest.maxTitleLength)
        #expect(!title.dropLast().hasSuffix(" "))
    }

    @Test func taskIsAChatTaskWithTheWholeRequest() throws {
        #expect(LeadRequest.task(text: "   \n", projectID: 1, workflowID: "feature-delivery") == nil)
        let task = try #require(LeadRequest.task(text: " Export orders\nas CSV ", projectID: 7, workflowID: "feature-delivery"))
        #expect(task.projectId == 7)
        #expect(task.title == "Export orders")
        #expect(task.body == "Export orders\nas CSV")
        #expect(task.source == .chat)
        #expect(task.status == .incoming)
        #expect(task.workflow == "feature-delivery")
    }

    @Test func onlyWorkflowsWithALeadStepHaveALead() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "ensemble-lead-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try ProjectConfigLoader.installDefaults(repository: repository)
        try LegacyWorkflows.install(repository: repository)
        let config = ProjectConfigLoader.load(repository: repository)
        let workflow = try #require(config.workflow("feature-delivery"))

        #expect(config.issues.isEmpty, "\(config.issues)")
        #expect(workflow.hasLead)
        #expect(workflow.steps.map(\.agent) == [.lead, .builder, .lead, .checker, nil])
        #expect(try #require(config.workflow("small-task")).hasLead == false)
    }

    @Test func leadOrderingPutsActiveRunsFirstThenNewest() {
        let base = Date(timeIntervalSince1970: 1_000)
        func run(_ id: Int64, _ status: RunStatus, minutes: Double) -> Run {
            Run(id: id, projectId: 1, taskId: id, workflow: "w", status: status, startedAt: base.addingTimeInterval(minutes * 60))
        }
        let runs = [run(1, .succeeded, minutes: 30), run(2, .running, minutes: 0), run(3, .waitingOnYou, minutes: 10), run(4, .failed, minutes: 5)]
        #expect(Run.leadOrdering(runs).map(\.id) == [3, 2, 1, 4])
    }

    @Test func partitionKeepsOpenOrderAndListsClosedNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        func request(_ id: Int64, closedMinutes: Double? = nil) -> Chat {
            Chat(
                id: id, projectId: 1, title: "R\(id)", body: "", source: .chat, status: .done,
                closedAt: closedMinutes.map { base.addingTimeInterval($0 * 60) }, closeReason: closedMinutes.map { _ in .done },
                createdAt: base, updatedAt: base
            )
        }
        let requests = [request(1), request(2, closedMinutes: 5), request(3), request(4, closedMinutes: 20), request(5, closedMinutes: 10)]

        let partition = LeadRequest.partition(requests)

        #expect(partition.open.map(\.id) == [1, 3])
        #expect(partition.closed.map(\.id) == [4, 5, 2])
        #expect(partition.closed.allSatisfy(\.isClosed) && !partition.open.contains(where: \.isClosed))
    }

    @Test func requestClosingMigrationKeepsExistingTasksOpen() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v9-direct-messages")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO project (name, path, isOpen, createdAt, lastOpenedAt) VALUES ('p', '/tmp/p', 1, ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO task (projectId, title, source, status, createdAt, updatedAt) VALUES (1, 'Old', 'chat', 'done', ?, ?)", arguments: [Date(), Date()])
        }

        let database = try AppDatabase(queue)

        let task = try #require(try database.task(id: 1))
        #expect(task.title == "Old" && task.status == .done)
        #expect(!task.isClosed && task.closeReason == nil)
        let closed = try #require(try database.setClosed(taskId: 1, reason: .dropped, at: Date(timeIntervalSince1970: 2_000)))
        #expect(closed.closeReason == .dropped && closed.closedAt == Date(timeIntervalSince1970: 2_000))
    }
}

@MainActor
@Suite(.serialized) struct RunTimelineTests {
    typealias H = WorkflowHarness

    @Test func planHoldExposesThePendingPlanAndStages() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan, costUSD: 0.5)))
        let workflow = try h.workflow("feature-delivery")
        let id = try await h.start(workflow)

        let timeline = try h.database.timeline(for: try h.run(id), workflow: try h.engine.workflow(for: try h.run(id)))
        #expect(timeline.pendingPlan == H.plan)
        #expect(timeline.holdItem?.kind == .planApproval)
        #expect(timeline.holdItem?.body.contains("Refund API") == true)
        #expect(timeline.approvedPlan == nil)
        #expect(timeline.currentStepTitle == "Plan & split the task")
        #expect(timeline.stages.map(\.id) == ["plan", "build", "review", "qa", "approve", "end"])
        #expect(timeline.stages.map(\.state) == [.waiting, .upcoming, .upcoming, .upcoming, .upcoming, .upcoming])
        #expect(timeline.entries.map(\.status) == [.waitingOnYou])
        #expect(timeline.entries.first?.costUSD == 0.5)
    }

    @Test func historyShowsLoopsOutcomesAndSummaries() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)))
        h.driver.script("build", H.done("Built v1"), H.done("Fixed rounding"))
        h.driver.script("review",
            H.verdict(StepOutcome.changesRequested, "Rounding is wrong", issues: [ReviewIssue(description: "Use cents", file: "refunds.py")]),
            H.verdict(StepOutcome.approved, "Looks good"))
        h.driver.script("qa", H.verdict(StepOutcome.passed, "All green"))
        let id = try await h.start(try h.workflow("feature-delivery"))
        var edited = H.plan
        edited.removeTask(id: "ui")
        try h.engine.approvePlan(try h.run(id), plan: edited)
        await h.settle(id)

        let run = try h.run(id)
        let timeline = try h.database.timeline(for: run, workflow: try h.engine.workflow(for: run))
        #expect(timeline.entries.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve"])
        #expect(timeline.entries.map(\.iteration) == [1, 1, 1, 2, 2, 1, 1])
        #expect(timeline.entries[2].outcomeTitle == "Changes requested")
        #expect(timeline.entries[2].summary == "Rounding is wrong")
        #expect(timeline.entries[2].issues.first?.file == "refunds.py")
        #expect(timeline.entries[3].summary == "Fixed rounding")
        #expect(timeline.approvedPlan == edited)
        #expect(timeline.pendingPlan == nil)
        #expect(timeline.currentStepTitle == "You approve the pins")
        #expect(timeline.stages.map(\.state) == [.done, .done, .done, .done, .waiting, .upcoming])

        try h.engine.resolveApproval(run, approved: true)
        await h.settle(id)
        let finished = try h.run(id)
        let done = try h.database.timeline(for: finished, workflow: try h.engine.workflow(for: finished))
        #expect(done.stages.allSatisfy { $0.state == .done })
        #expect(done.entries.last?.title == "Finish")
    }

    @Test func failureHoldMarksTheStageFailedAndListsOpenQuestions() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", .failure("Tests crashed"))
        let id = try await h.start(try h.workflow("small-task"))
        let projectID = try #require(h.project.id)
        let agent = try h.database.insert(Agent(projectId: projectID, runId: id, role: "claude-code", name: "Dev 1", status: .working, createdAt: .now, updatedAt: .now))
        try h.database.createChatRequest(ChatRequest(projectId: projectID, runId: id, agentId: agent.id, kind: .question, title: "Squash migrations?", createdAt: .now))
        let answered = try h.database.createChatRequest(ChatRequest(projectId: projectID, runId: id, kind: .question, title: "Old question", createdAt: .now))
        try h.database.resolveChatRequest(id: try #require(answered.id), response: "Yes")

        let run = try h.run(id)
        let timeline = try h.database.timeline(for: run, workflow: try h.engine.workflow(for: run))
        #expect(try h.hold(id)?.reason == .stepFailed)
        #expect(timeline.stages.first?.state == .failed)
        #expect(timeline.holdItem?.kind == .failure)
        #expect(timeline.entries.first?.summary == "Tests crashed")
        #expect(timeline.questions.map(\.title) == ["Squash migrations?"])
        #expect(timeline.questions.first?.agentId == agent.id)
    }
}
