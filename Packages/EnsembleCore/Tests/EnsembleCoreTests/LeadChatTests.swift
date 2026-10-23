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
        #expect(allowed.contains("ArtifactData"))
        #expect(allowed.contains("ArtifactComments"))
        #expect(allowed.contains("ArtifactCheck"))
        #expect(allowed.contains("Artifact(read)"))
        #expect(!allowed.contains("Artifact"))
        #expect(allowed.contains("mcp__ensemble__propose_run"))
        #expect(allowed.contains("mcp__ensemble__message_agent"))

        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        let turn = try setup.harness.runtime.turnSetup(for: leadAgent)
        #expect(Array(turn.extraAllowedTools.prefix(2)) == AgentPermissions.webTools)
        #expect(Array(turn.extraAllowedTools.dropFirst(2).prefix(4)) == AgentPermissions.artifactTools)
        #expect(turn.systemPrompt.contains("`WebFetch` and `WebSearch`"))
        #expect(turn.systemPrompt.contains("open a claude.ai artifact link the user shares, call `Artifact` with `action: \"read\"`"))
        #expect(turn.systemPrompt.contains("never fetch artifact links with `WebFetch`"))
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
            #expect(!allowed.contains { AgentPermissions.artifactTools.contains($0) || $0.hasPrefix("Artifact") }, "\(session.agent.name)")
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

        let runLeads = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id && $0.role == "tech-lead" }
        let chatLead = try #require(runLeads.first { $0.taskId == task.id })
        let reviewer = try #require(runLeads.first { $0.taskId == nil })
        #expect(runLeads.count == 2)
        #expect(reviewer.readOnly && reviewer.costUSD > 0)
        let chatTranscript = try String(contentsOf: setup.harness.runtime.paths.transcript(chatLead.id!), encoding: .utf8)
        #expect(chatTranscript.contains("Roles that can build"))
        #expect(!chatTranscript.contains("# Review the code"))

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

    func startedRun(_ setup: Setup, _ chat: LeadChat, lead: RoleDefinition) async throws -> (ProjectTask, Run) {
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let run = try chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        return (task, run)
    }

    func stored(_ setup: Setup, _ task: ProjectTask) throws -> ProjectTask {
        try #require(try setup.harness.database.task(id: task.id!))
    }

    @Test func closingAsDoneOrDroppedRecordsTheReason() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let finished = try await chat.createRequest("CHAT finished", lead: lead, in: setup.project)
        let abandoned = try await chat.createRequest("CHAT abandoned", lead: lead, in: setup.project)
        try await waitUntil { [finished, abandoned].allSatisfy { messages(setup, $0).contains { $0.kind == .lead } } }
        let doneAt = Date(timeIntervalSince1970: 2_000_000_000)
        let droppedAt = doneAt.addingTimeInterval(60)

        let done = try await chat.close(finished, as: .done, in: setup.project, git: setup.harness.repo.git, now: doneAt)
        let dropped = try await chat.close(abandoned, as: .dropped, in: setup.project, git: setup.harness.repo.git, now: droppedAt)

        #expect(done.isClosed && done.closeReason == .done && done.closedAt == doneAt && done.updatedAt == doneAt)
        #expect(dropped.isClosed && dropped.closeReason == .dropped && dropped.closedAt == droppedAt)
        #expect(try stored(setup, finished) == done)
        #expect(try stored(setup, abandoned) == dropped)
        #expect(RequestCloseReason.allCases.map(\.title) == ["Done", "Dropped"])
    }

    @Test func closingIsRefusedWhileARunIsActiveAndARunEndingKeepsTheClosedState() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat, lead: lead)

        await #expect(throws: LeadChatError.runInProgress) {
            try await chat.close(task, as: .done, in: setup.project, git: setup.harness.repo.git)
        }
        #expect(try !stored(setup, task).isClosed)
        let requests = try setup.harness.database.leadRequests(projectId: setup.project.id!)
        #expect(LeadRequest.partition(requests).open.map(\.id) == [task.id])
        #expect(try setup.harness.database.leadAgent(taskId: task.id!)?.status != .stopped)

        let closedAt = Date(timeIntervalSince1970: 2_000_000_000)
        try setup.harness.database.setClosed(taskId: task.id!, reason: .dropped, at: closedAt)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))

        let ended = try stored(setup, task)
        #expect(ended.status == .incoming)
        #expect(ended.closedAt == closedAt && ended.closeReason == .dropped)
    }

    @Test func closingStopsTheRequestsAgentsAndRemovesOnlyTheirWorktrees() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat, lead: lead)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
        let builder = try await setup.harness.runtime.createRunAgent(
            in: setup.project, role: try #require(setup.config.role("claude-code")), runId: run.id!, runStepId: nil,
            task: "Add alpha", git: setup.harness.repo.git
        )
        let builderWorktree = try #require(builder.agent.worktreeURL)
        let builderBranch = try #require(builder.agent.branch)
        let outsider = try await setup.harness.repo.manager.create(agent: "Outsider", slug: "keep")
        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        let leadSession = try #require(setup.harness.runtime.session(for: leadAgent))
        try await waitUntil { !leadSession.isRunning }
        let messagesBefore = messages(setup, task)

        let closed = try await chat.close(task, as: .dropped, in: setup.project, git: setup.harness.repo.git)

        #expect(closed.closeReason == .dropped)
        #expect(!leadSession.isRunning && leadSession.agent.status == .stopped)
        #expect(builder.agent.status == .stopped && builder.agent.archivedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: builderWorktree.path))
        let remaining = try await setup.harness.repo.manager.list().map(\.agent)
        #expect(remaining == [outsider.agent])
        let branches = try await setup.harness.repo.git.run(["branch", "--list", builderBranch], in: setup.harness.repo.root)
        #expect(branches.contains(builderBranch))
        let agentIDs = try setup.harness.database.agents(inProject: setup.project.id!).map(\.id)
        #expect(agentIDs.contains(leadAgent.id) && agentIDs.contains(builder.id))
        #expect(try setup.harness.database.leadAgent(taskId: task.id!)?.id == leadAgent.id)
        #expect(messages(setup, task) == messagesBefore)
    }

    @Test func sendingToAClosedRequestReopensItAndTheLeadAnswers() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let closed = try await chat.close(task, as: .done, in: setup.project, git: setup.harness.repo.git)
        let projectID = setup.project.id!
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: projectID)).closed.map(\.id) == [task.id])
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: projectID)).open.isEmpty)
        let launchesBefore = setup.harness.launches().count

        try await chat.send("CHAT one more thing", to: closed, lead: lead, in: setup.project)

        let reopened = try stored(setup, task)
        #expect(!reopened.isClosed && reopened.closeReason == nil)
        #expect(reopened.updatedAt > closed.updatedAt)
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: projectID)).open.map(\.id) == [task.id])
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }
        #expect(messages(setup, task).map(\.kind) == [.user, .lead, .user, .lead])
        #expect(setup.harness.launches().count == launchesBefore + 1)
        #expect(setup.harness.launches().last?.contains("--resume") == true)
        #expect(try setup.harness.database.agents(inProject: projectID).filter { $0.taskId == task.id }.count == 1)
    }

    @Test func startingAnOpenProposalOnAClosedRequestReopensIt() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let proposal = try #require(messages(setup, task).first { $0.kind == .proposal })
        try await chat.close(task, as: .dropped, in: setup.project, git: setup.harness.repo.git)

        let run = try chat.start(proposal, in: setup.project)

        #expect(run.isActive && run.taskId == task.id)
        let reopened = try stored(setup, task)
        #expect(!reopened.isClosed && reopened.closeReason == nil)
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: setup.project.id!)).open.map(\.id) == [task.id])
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func closingAgainSkipsAgentsAnEarlierCloseAlreadyRetired() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat, lead: lead)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
        let builder = try await setup.harness.runtime.createRunAgent(
            in: setup.project, role: try #require(setup.config.role("claude-code")), runId: run.id!, runStepId: nil,
            task: "Add alpha", git: setup.harness.repo.git
        )
        try await chat.close(task, as: .done, in: setup.project, git: setup.harness.repo.git)
        let noticesAfterFirstClose = builder.transcript.entries.count
        let archivedAt = builder.agent.archivedAt

        try await chat.send("CHAT back again", to: try stored(setup, task), lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }
        try await chat.close(try stored(setup, task), as: .dropped, in: setup.project, git: setup.harness.repo.git)

        #expect(builder.transcript.entries.count == noticesAfterFirstClose)
        #expect(builder.agent.archivedAt == archivedAt)
        #expect(try stored(setup, task).closeReason == .dropped)
    }

    @Test func aRequestCanBeOnlyAttachments() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try StdinRecorder.install(in: setup.harness)
        let paste = ChatAttachment.pastedText(id: UUID(), index: 1, text: "CHAT crash log\n" + String(repeating: "frame\n", count: 30))
        let image = try ChatAttachment.image(data: try TestImages.encoded(width: 10, height: 10, as: .png), fileName: "shot.png")

        let task = try await chat.createRequest("", attachments: [paste, image], lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        #expect(task.title == "CHAT crash log")
        #expect(task.body == ChatAttachment.prompt(text: "", attachments: [paste]))
        let sent = try #require(messages(setup, task).first)
        #expect(sent.kind == .user && sent.text == "")
        #expect(sent.chatAttachments == [paste, image])

        let line = try #require(StdinRecorder.lines(in: setup.harness).last)
        let blocks = try #require(line["message"]?["content"]?.array)
        #expect(blocks.map { $0["type"]?.string } == ["text", "image"])
        #expect(blocks[0]["text"]?.string?.contains("<pasted-text number=\"1\">\nCHAT crash log") == true)
        #expect(blocks[1]["source"]?["data"]?.string == image.imageData?.base64EncodedString())
    }

    @Test func followUpsCarryAttachmentsAndTheTypedTextStaysPlain() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try StdinRecorder.install(in: setup.harness)
        let image = try ChatAttachment.image(data: try TestImages.encoded(width: 10, height: 10, as: .png), fileName: "shot.png")
        let task = try await chat.createRequest("", attachments: [image], lead: lead, in: setup.project)
        #expect(task.title == "Image")
        #expect(task.body == "")

        try await waitUntil { chat.leadSession(for: task).map { !$0.isRunning && $0.agent.status == .idle } == true }
        try await chat.send("CHAT what about this one?", attachments: [image], to: task, lead: lead, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        #expect(messages(setup, task).filter { $0.kind == .user }.map(\.text) == ["", "CHAT what about this one?"])
        let line = try #require(StdinRecorder.lines(in: setup.harness).last)
        #expect(StdinRecorder.imageBlocks(line).count == 1)
    }

    @Test func requestsNeedTextOrAttachments() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        await #expect(throws: AgentError.emptyTask) { try await chat.createRequest("  ", lead: lead, in: setup.project) }
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

    @Test func aProposalShowsAfterTheLeadsReplyFromTheSameTurn() {
        let thread = RequestThread(
            task: task, messages: [message(1, .user, 1), message(2, .proposal, 2), message(3, .lead, 3), message(4, .user, 4), message(5, .proposal, 5)],
            runs: [], timelines: [:], questions: [], heldRunIDs: []
        )
        #expect(thread.items.map(\.id) == ["message-1", "message-3", "message-2", "message-4", "message-5"])
    }

    @Test func olderRequestsWithoutMessagesStartWithTheirBodyAndEndWithTheResult() {
        let run = Run(id: 8, projectId: 1, taskId: 1, workflow: "small-task", status: .succeeded, startedAt: at(1), endedAt: at(9))
        let thread = RequestThread(task: task, messages: [], runs: [run], timelines: [:], questions: [], heldRunIDs: [8])
        #expect(thread.items.map(\.id) == ["request-1", "run-8", "end-8"])
    }
}
