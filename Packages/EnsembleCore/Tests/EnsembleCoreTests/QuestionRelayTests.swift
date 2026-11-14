import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct QuestionRelayTests {
    final class Deliveries {
        var batches: [(runId: Int64, questions: [RelayedQuestion])] = []
    }

    func question(_ body: String, from name: String, agentId: Int64, runId: Int64 = 1, questions: [HumanQuestion] = []) -> RelayedQuestion {
        RelayedQuestion(projectId: 1, runId: runId, agentId: agentId, agentName: name, body: body, questions: questions)
    }

    @Test func questionsInsideTheWindowAreDeliveredTogetherOncePerRun() async throws {
        let deliveries = Deliveries()
        let relay = QuestionRelay(window: .milliseconds(50)) { runId, batch in deliveries.batches.append((runId, batch)) }

        relay.enqueue(question("Postgres is down", from: "Dev 1", agentId: 1))
        relay.enqueue(question("Docker isn’t allowed", from: "Dev 2", agentId: 2))
        relay.enqueue(question("Other run", from: "Dev 3", agentId: 3, runId: 2))
        #expect(deliveries.batches.isEmpty)

        try await waitUntil { deliveries.batches.count == 2 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(deliveries.batches.count == 2)
        #expect(deliveries.batches.first { $0.runId == 1 }?.questions.map(\.agentName) == ["Dev 1", "Dev 2"])
        #expect(deliveries.batches.first { $0.runId == 2 }?.questions.map(\.agentName) == ["Dev 3"])
        #expect(!relay.hasPendingTimers)
        #expect(relay.bufferedRunIDs.isEmpty)
    }

    @Test func flushingEarlyDeliversAtOnceAndCancelsTheTimer() async throws {
        let deliveries = Deliveries()
        let relay = QuestionRelay(window: .milliseconds(50)) { runId, batch in deliveries.batches.append((runId, batch)) }

        relay.enqueue(question("Which port?", from: "Dev 1", agentId: 1))
        relay.flush(runId: 1)

        #expect(deliveries.batches.count == 1)
        #expect(!relay.hasPendingTimers)
        try await Task.sleep(for: .milliseconds(150))
        #expect(deliveries.batches.count == 1)

        relay.flush(runId: 1)
        #expect(deliveries.batches.count == 1)
    }

    @Test func aQuestionAfterAFlushStartsANewWindow() async throws {
        let deliveries = Deliveries()
        let relay = QuestionRelay(window: .milliseconds(50)) { runId, batch in deliveries.batches.append((runId, batch)) }

        relay.enqueue(question("First", from: "Dev 1", agentId: 1))
        relay.flush(runId: 1)
        relay.enqueue(question("Second", from: "Dev 1", agentId: 1))
        #expect(relay.hasPendingTimers)

        try await waitUntil { deliveries.batches.count == 2 }
        #expect(deliveries.batches.map { $0.questions.map(\.body) } == [["First"], ["Second"]])
    }

    @Test func theLeadMessageNamesEachAgentWithTheirQuestionsAndSaysWhatToDo() {
        let message = QuestionRelay.message(for: [
            question("Postgres on localhost:5432 is down.", from: "Dev 1", agentId: 1, questions: [
                HumanQuestion(question: "How should I run the tests?", options: ["Start Docker", "Use SQLite"]),
                HumanQuestion(question: "Anything else?"),
            ]),
            question("Same here, the database is down.", from: "Dev 2", agentId: 2),
        ])

        #expect(message.hasPrefix("Questions from your run’s agents (sent by Ensemble, not the user):"))
        #expect(message.contains("## Dev 1 asks:\nPostgres on localhost:5432 is down.\n1. How should I run the tests?\n   Options: Start Docker; Use SQLite\n2. Anything else?"))
        #expect(message.contains("## Dev 2 asks:\nSame here, the database is down."))
        #expect(message.contains("`mcp__ensemble__message_agent`"))
        #expect(message.contains("ONE `mcp__ensemble__ask_human`"))
        #expect(message.contains("`mcp__ensemble__open_worktree`"))
        #expect(message.contains("names which agents each point affects"))
        #expect(message.contains("After the user answers"))
    }

    @MainActor
    struct LeadRun {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let run: Run
        let lead: Agent
        let builders: [Agent]

        var database: AppDatabase { harness.database }

        func leadTranscript() -> String {
            (try? String(contentsOf: harness.runtime.paths.transcript(lead.id!), encoding: .utf8)) ?? ""
        }

        func questionItems() throws -> [ChatRequest] {
            try database.openChatRequests(projectId: harness.project.id!).filter { $0.kind == .question }
        }
    }

    func makeLeadRun(workflow workflowID: String = "feature-delivery", withLead: Bool = true) async throws -> LeadRun {
        let harness = try await AgentHarness.make(mode: "workflow")
        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        try LegacyWorkflows.install(repository: harness.repo.root)
        let config = ProjectConfigLoader.load(repository: harness.repo.root)
        let workflow = try #require(config.workflow(workflowID))
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.pollInterval = .milliseconds(20)
        driver.questionWindow = .milliseconds(50)

        let projectId = try #require(harness.project.id)
        let now = Date()
        let task = try harness.database.insert(ProjectTask(
            projectId: projectId, title: "Add alpha and beta", body: "Two files, please.", source: .chat,
            status: .incoming, createdAt: now, updatedAt: now
        ))
        let taskId = try #require(task.id)
        let run = try harness.database.insert(Run(
            projectId: projectId, taskId: taskId, workflow: workflowID, status: .running, startedAt: now,
            title: task.title, workflowSnapshot: try ProjectConfigLoader.encodeYAML(workflow)
        ), state: RunEngineState())
        let runId = try #require(run.id)

        let lead = try harness.runtime.createLeadAgent(in: harness.project, taskId: taskId)
        lead.attach(toRun: runId)
        let builders = try ["Dev 1", "Dev 2"].map { name in
            try harness.database.insert(Agent(
                projectId: projectId, runId: runId, role: "builder", name: name, status: .idle, readOnly: true, createdAt: now, updatedAt: now
            ))
        }
        if !withLead {
            try harness.database.deleteAgent(id: lead.id)
        }
        return LeadRun(harness: harness, driver: driver, run: run, lead: lead.agent, builders: builders)
    }

    @Test func aRunAgentsQuestionGoesToTheLeadInsteadOfTheUser() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }

        let reply = try await setup.driver.receive(.question("Postgres on localhost:5432 is down, so I can’t run the tests."), from: setup.builders[0].id!)

        #expect(reply == "Your question was sent to your lead, who will answer it or ask the user. End your turn now; the answer arrives as your next message.")
        #expect(try setup.questionItems().isEmpty)
        try await waitUntil { setup.leadTranscript().contains("Questions from your run’s agents") }
        let transcript = setup.leadTranscript()
        #expect(transcript.contains("Dev 1 asks:"))
        #expect(transcript.contains("Postgres on localhost:5432 is down, so I can’t run the tests."))
        #expect(try setup.questionItems().isEmpty)
        #expect(try setup.database.requestQuestions(taskId: setup.run.taskId).isEmpty)
        #expect(!setup.driver.questionRelay.hasPendingTimers)
    }

    @Test func twoAgentsAskingInsideTheWindowReachTheLeadInOneMessage() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }

        _ = try await setup.driver.receive(.question("Postgres is down.", [HumanQuestion(question: "Start Docker?", options: ["Yes", "No"])]), from: setup.builders[0].id!)
        _ = try await setup.driver.receive(.question("The database is down for me too."), from: setup.builders[1].id!)

        try await waitUntil { setup.leadTranscript().contains("Questions from your run’s agents") }
        try await Task.sleep(for: .milliseconds(150))
        let transcript = setup.leadTranscript()
        #expect(transcript.components(separatedBy: "Questions from your run’s agents").count == 2)
        #expect(transcript.contains("Dev 1 asks:"))
        #expect(transcript.contains("Start Docker?"))
        #expect(transcript.contains("Options: Yes; No"))
        #expect(transcript.contains("Dev 2 asks:"))
        #expect(transcript.contains("The database is down for me too."))
        #expect(try setup.questionItems().isEmpty)
    }

    @Test func aRunWithoutALeadStepStillAsksTheUser() async throws {
        let setup = try await makeLeadRun(workflow: "small-task")
        defer { setup.harness.cleanUp() }

        let reply = try await setup.driver.receive(.question("Which database?"), from: setup.builders[0].id!)

        #expect(reply == "Your question was sent to the user. End your turn now; the answer arrives as your next message.")
        let items = try setup.questionItems()
        #expect(items.map(\.body) == ["Which database?"])
        #expect(items.first?.agentId == setup.builders[0].id)
        #expect(items.first?.title == "Dev 1 asks")
        #expect(setup.driver.questionRelay.bufferedRunIDs.isEmpty)
    }

    @Test func aRunWithoutARequestLeadStillAsksTheUser() async throws {
        let setup = try await makeLeadRun(withLead: false)
        defer { setup.harness.cleanUp() }

        _ = try await setup.driver.receive(.question("Which database?"), from: setup.builders[0].id!)

        #expect(try setup.questionItems().map(\.body) == ["Which database?"])
    }

    @Test func questionsBecomeInboxItemsWhenTheLeadIsGoneAtFlushTime() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }
        let options = [HumanQuestion(question: "Start Docker?", options: ["Yes", "No"])]

        _ = try await setup.driver.receive(.question("Postgres is down.", options), from: setup.builders[0].id!)
        _ = try await setup.driver.receive(.question("Me too."), from: setup.builders[1].id!)
        try setup.database.deleteAgent(id: setup.lead.id!)

        try await waitUntil { (try? setup.questionItems().count) == 2 }
        let items = try setup.questionItems().sorted { $0.agentId ?? 0 < $1.agentId ?? 0 }
        #expect(items.map(\.title) == ["Dev 1 asks", "Dev 2 asks"])
        #expect(items.map(\.body) == ["Postgres is down.", "Me too."])
        #expect(items.map(\.runId) == [setup.run.id, setup.run.id])
        #expect(items.first?.questions == options)
        #expect(items.last?.questions == nil)
        #expect(!setup.leadTranscript().contains("Questions from your run’s agents"))
    }

    @Test func theLeadsOwnQuestionStillGoesToTheUser() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }

        let reply = try await setup.driver.receive(.question("Ship it on Friday?"), from: setup.lead.id!)

        #expect(reply.contains("sent to the user"))
        let items = try setup.questionItems()
        #expect(items.map(\.body) == ["Ship it on Friday?"])
        #expect(items.first?.agentId == setup.lead.id)
        #expect(setup.driver.questionRelay.bufferedRunIDs.isEmpty)
    }

    @Test func anAgentWaitingOnItsLeadIsNotNudgedUntilTheLeadReplies() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }
        let builder = try #require(setup.harness.runtime.session(for: setup.builders[0]))
        let transcript = { (try? String(contentsOf: setup.harness.runtime.paths.transcript(builder.id), encoding: .utf8)) ?? "" }

        _ = try await setup.driver.receive(.question("Which database?"), from: builder.id)
        let follow = Task { try await setup.driver.follow(builder, expected: .verdict) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!transcript().contains("You ended your turn"))

        let sent = try await setup.driver.receive(.agentMessage(agent: "Dev 1", message: "Use SQLite."), from: setup.lead.id!)
        #expect(sent == "Sent to Dev 1.")

        await #expect(throws: WorkflowDriverError.self) { try await follow.value }
        #expect(transcript().contains("Use SQLite."))
        #expect(transcript().contains("You ended your turn"))
    }

    @Test func cancellingARunFlushesBufferedQuestionsAndStopsTheTimer() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }
        setup.driver.questionWindow = .seconds(60)

        _ = try await setup.driver.receive(.question("Postgres is down."), from: setup.builders[0].id!)
        #expect(setup.driver.questionRelay.hasPendingTimers)

        await setup.driver.cancel(setup.run)

        #expect(!setup.driver.questionRelay.hasPendingTimers)
        #expect(setup.driver.questionRelay.bufferedRunIDs.isEmpty)
        try await waitUntil { setup.leadTranscript().contains("Questions from your run’s agents") }
        #expect(setup.leadTranscript().contains("Postgres is down."))
    }

    @Test func finishingARunFlushesBufferedQuestionsToTheInboxWhenTheLeadIsGone() async throws {
        let setup = try await makeLeadRun()
        defer { setup.harness.cleanUp() }
        setup.driver.questionWindow = .seconds(60)

        _ = try await setup.driver.receive(.question("Postgres is down."), from: setup.builders[0].id!)
        try setup.database.deleteAgent(id: setup.lead.id!)

        _ = try await setup.driver.finish(setup.run, end: WorkflowEnd(action: .leave, cleanUpWorktrees: false))

        #expect(!setup.driver.questionRelay.hasPendingTimers)
        #expect(setup.driver.questionRelay.bufferedRunIDs.isEmpty)
        #expect(try setup.questionItems().map(\.body) == ["Postgres is down."])
    }
}
