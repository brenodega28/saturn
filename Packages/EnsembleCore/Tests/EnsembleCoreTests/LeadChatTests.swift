import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct LeadChatTests {
    typealias Setup = WorkflowDriverTests.Setup

    func makeChat() async throws -> (Setup, LeadChat, RoleDefinition) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let chat = LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver)
        #expect(setup.harness.runtime.mcpServer == nil)
        return (setup, chat, try #require(setup.config.role("tech-lead")))
    }

    func messages(_ setup: Setup, _ task: ProjectTask) -> [LeadMessage] {
        (try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []
    }

    @Test func aNewRequestStartsAChatWithItsOwnLeadAndRecordsTheFinalReply() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }

        let task = try await chat.createRequest("CHAT what is in this repo?", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        #expect(messages(setup, task).map(\.kind) == [.user, .lead])
        #expect(messages(setup, task).map(\.text) == ["CHAT what is in this repo?", "The repo only has a README."])
        let agent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(agent.role == "tech-lead" && agent.readOnly && agent.runId == nil && agent.worktreePath == nil)
        #expect(try setup.harness.database.runs(taskId: task.id!).isEmpty)
        let launch = try #require(setup.harness.launches().last)
        #expect(launch.contains("mcp__ensemble__propose_run"))
        #expect(launch.contains("mcp__ensemble__message_agent"))
        #expect(launch.contains("Chatting with the user"))
        #expect(launch.contains("`feature-delivery`"))
        #expect(try setup.harness.database.leadRequests(projectId: setup.project.id!).map(\.id) == [task.id])
    }

    func allowedTools(_ arguments: [String]) throws -> [String] {
        let index = try #require(arguments.lastIndex(of: "--allowedTools"))
        return Array(arguments[(index + 1)...])
    }

    func launchArguments(_ setup: TurnSetup) -> [String] {
        ClaudeLaunch(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            worktree: setup.directory,
            session: .new("abc"),
            model: "sonnet",
            systemPrompt: setup.systemPrompt,
            environment: [:],
            readOnly: setup.readOnly,
            additionalDirectories: setup.additionalDirectories,
            extraArguments: setup.extraArguments,
            extraAllowedTools: setup.extraAllowedTools
        ).arguments
    }

    @Test func theChatLeadMayFetchAndSearchTheWebAlongsideItsHandoffTools() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT what is in this repo?", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        let launch = try #require(setup.harness.launches().last)
        let allowed = try allowedTools(launch.split(separator: " ").map(String.init))
        #expect(allowed.contains("WebFetch"))
        #expect(allowed.contains("WebSearch"))
        #expect(allowed.contains("mcp__ensemble__propose_run"))
        #expect(allowed.contains("mcp__ensemble__message_agent"))

        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        let turn = try setup.harness.runtime.turnSetup(for: leadAgent)
        #expect(Array(turn.extraAllowedTools.prefix(2)) == AgentPermissions.webTools)
        #expect(turn.systemPrompt.contains("`WebFetch` and `WebSearch`"))
    }

    @Test func agentsOutsideTheChatGetNoWebTools() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        #expect(setup.harness.runtime.mcpServer != nil)

        let reviewer = RoleDefinition(id: "pr-reviewer", name: "PR Reviewer", editsCode: false)
        let builder = RoleDefinition(id: "claude-code", name: "Claude Code")
        let config = ProjectConfig(roles: [reviewer, builder, lead])
        let runtime = setup.harness.runtime
        let git = setup.harness.repo.git
        var others: [AgentSession] = []
        for role in [reviewer, builder, lead] {
            others += try await runtime.spawn(in: setup.project, role: role, count: 1, config: config, git: git)
        }

        #expect(others.count == 3)
        for session in others {
            #expect(session.agent.taskId == nil)
            let allowed = try allowedTools(launchArguments(try runtime.turnSetup(for: session.agent)))
            #expect(!allowed.contains { AgentPermissions.webTools.contains($0) }, "\(session.agent.name)")
        }
    }

    @Test func aStartedProposalIsPlannedByTheSameLeadWithTheBrief() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        try await chat.send("CHAT-PROPOSE build alpha and beta", to: task, lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let proposal = try #require(messages(setup, task).first { $0.kind == .proposal })
        #expect(proposal.status == .open && proposal.workflow == "feature-delivery" && proposal.title == "Add alpha and beta")
        #expect(try setup.harness.database.runs(taskId: task.id!).isEmpty)

        let run = try chat.start(proposal, in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)

        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(leadAgent.runId == run.id)
        let runLeads = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id && $0.role == "tech-lead" }
        #expect(runLeads.map(\.id) == [leadAgent.id])
        #expect(run.title == "Add alpha and beta")
        let input = try #require(try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }?.input)
        #expect(input.contains("Create alpha.txt and beta.txt, as agreed."))
        #expect(messages(setup, task).first { $0.id == proposal.id }?.status == .started)

        #expect(throws: LeadChatError.proposalClosed) { try chat.start(proposal, in: setup.project) }
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.proposal(RunProposal(workflow: "feature-delivery", title: "Again", brief: "x")), from: leadAgent.id!)
        }
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func theLeadRelaysToRunAgentsAndSeesTheRunStatus() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let run = try chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let plan = try #require(try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }?.output
            .flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let note = try #require(try chat.statusNote(taskId: task.id!))
        #expect(note.contains("“Add alpha and beta” is waiting for the user"))
        #expect(note.contains("It is waiting for the user: an approval step."))
        let builder = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.runId == run.id && $0.planTaskId != nil })
        #expect(note.contains(builder.name))

        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        let launchesBefore = setup.harness.launches().count
        let reply = try await setup.driver.receive(.agentMessage(agent: builder.name.uppercased(), message: "Also add gamma"), from: leadAgent.id!)
        #expect(reply == "Sent to \(builder.name).")
        try await waitUntil { setup.harness.launches().count > launchesBefore }
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.agentMessage(agent: "Nobody 9", message: "x"), from: leadAgent.id!)
        }
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func dismissedProposalsCantStart() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let proposal = try #require(messages(setup, task).first { $0.kind == .proposal })

        try chat.dismiss(proposal)
        let dismissed = try #require(messages(setup, task).first { $0.id == proposal.id })
        #expect(dismissed.status == .dismissed)
        #expect(throws: LeadChatError.proposalClosed) { try chat.start(dismissed, in: setup.project) }
    }

    @Test func requestsNeedALeadRole() async throws {
        let (setup, chat, _) = try await makeChat()
        defer { setup.harness.cleanUp() }
        await #expect(throws: LeadChatError.noLeadRole) { try await chat.createRequest("Hello", lead: nil, in: setup.project) }
    }
}

@Suite struct RequestThreadTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    var task: ProjectTask {
        ProjectTask(id: 1, projectId: 1, title: "Add alpha", body: "Add alpha please", source: .chat, status: .running, createdAt: at(0), updatedAt: at(0))
    }

    func message(_ id: Int64, _ kind: LeadMessageKind, _ minutes: Double) -> LeadMessage {
        LeadMessage(id: id, projectId: 1, taskId: 1, kind: kind, text: "m\(id)", createdAt: at(minutes))
    }

    func entry(_ id: Int64, status: RunStepStatus, ended: Double?) -> RunTimeline.Entry {
        RunTimeline.Entry(
            id: id, stepId: "s\(id)", title: "Step \(id)", type: .agent, iteration: 1, status: status, outcome: nil, summary: nil,
            issues: [], plan: nil, costUSD: 0, startedAt: at(ended.map { $0 - 1 } ?? 9), endedAt: ended.map(at)
        )
    }

    @Test func itemsAreInTimeOrderWithLiveItemsAtTheBottom() throws {
        let run = Run(id: 7, projectId: 1, taskId: 1, workflow: "feature-delivery", status: .waitingOnYou, startedAt: at(3))
        let answered = InboxItem(id: 20, projectId: 1, runId: 7, kind: .question, title: "Q", status: .resolved, response: "Yes", createdAt: at(4), resolvedAt: at(5))
        let open = InboxItem(id: 21, projectId: 1, runId: 7, kind: .question, title: "Q2", createdAt: at(1))
        let timeline = RunTimeline(run: run, workflow: WorkflowDefinition(id: "w", name: "W", steps: []), steps: [], hold: nil)
        var withEntries = timeline
        withEntries.entries = [entry(30, status: .succeeded, ended: 4.5), entry(31, status: .running, ended: nil)]

        let thread = RequestThread(
            task: task, messages: [message(1, .user, 1), message(2, .lead, 2), message(3, .proposal, 2.5), message(4, .user, 6)],
            runs: [run], timelines: [7: withEntries], questions: [answered, open], heldRunIDs: [7]
        )

        #expect(thread.items.map(\.id) == ["message-1", "message-2", "message-3", "run-7", "step-30", "answer-20", "message-4", "question-21", "hold-7"])
        #expect(thread.items.suffix(2).allSatisfy { $0.isLive })
    }

    @Test func olderRequestsWithoutMessagesStartWithTheirBodyAndEndWithTheResult() {
        let run = Run(id: 8, projectId: 1, taskId: 1, workflow: "small-task", status: .succeeded, startedAt: at(1), endedAt: at(9))
        let thread = RequestThread(task: task, messages: [], runs: [run], timelines: [:], questions: [], heldRunIDs: [8])
        #expect(thread.items.map(\.id) == ["request-1", "run-8", "end-8"])
    }
}
