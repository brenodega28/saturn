import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct LeadChatTests {
    typealias Setup = WorkflowDriverTests.Setup

    func makeChat() async throws -> (Setup, LeadChat, RoleDefinition) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let chat = LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver)
        #expect(setup.harness.runtime.mcpServer == nil)
        return (setup, chat, setup.config.lead)
    }

    func messages(_ setup: Setup, _ task: Chat) -> [LeadMessage] {
        (try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []
    }

    @Test func aNewRequestStartsAChatWithItsOwnLeadAndRecordsTheFinalReply() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }

        let task = try await chat.createRequest("CHAT what is in this repo?", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        #expect(messages(setup, task).map(\.kind) == [.user, .lead])
        #expect(messages(setup, task).map(\.text) == ["CHAT what is in this repo?", "The repo only has a README."])
        let agent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(agent.kind == .lead && agent.name == "Lead" && agent.model == "opus" && agent.readOnly && agent.runId == nil && agent.worktreePath == nil)
        #expect(try setup.harness.database.runs(taskId: task.id!).isEmpty)
        let launch = try #require(setup.harness.launches().last)
        #expect(launch.contains("mcp__saturn__propose_run"))
        #expect(launch.contains("mcp__saturn__message_agent"))
        #expect(launch.contains("Chatting with the user"))
        #expect(launch.contains("questions the run's agents ask with `mcp__saturn__ask_human` come to you, not the user"))
        #expect(launch.contains("ONE merged `mcp__saturn__ask_human` that names the agents each point affects"))
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

    @Test func theLeadModelChosenForAChatIsUsedOnTheNextTurn() async throws {
        let (setup, chat, _) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        try chat.setLead(model: "sonnet", effort: .low, for: task)
        try await chat.send("CHAT again", to: try #require(try setup.harness.database.task(id: task.id!)), in: setup.project)
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }

        let agent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(agent.model == "sonnet")
        #expect(try setup.harness.database.task(id: task.id!)?.leadEffort == .low)
        #expect(setup.harness.launches().last?.contains("sonnet") == true)
    }

    @Test func aNewChatKeepsItsWorkflowAndLeadModelAndTellsTheLead() async throws {
        let (setup, chat, _) = try await makeChat()
        defer { setup.harness.cleanUp() }

        let task = try await chat.createRequest("CHAT hi", in: setup.project, workflow: "small-task", leadModel: "haiku", leadEffort: .high)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        let stored = try #require(try setup.harness.database.task(id: task.id!))
        #expect(stored.workflow == "small-task" && stored.leadModel == "haiku" && stored.leadEffort == .high)
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(lead.model == "haiku")
        let sent = setup.harness.runtime.session(for: lead)?.transcript.entries.compactMap { entry -> String? in
            if case .user(let text) = entry.content { return text }
            return nil
        } ?? []
        #expect(sent.contains { $0.contains("picked the `small-task` workflow") })
    }

    @Test func theChatLeadMayFetchAndSearchTheWebAlongsideItsHandoffTools() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT what is in this repo?", in: setup.project)
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
        #expect(allowed.contains("mcp__saturn__propose_run"))
        #expect(allowed.contains("mcp__saturn__message_agent"))

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
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        #expect(setup.harness.runtime.mcpServer != nil)

        #expect(lead.id == "lead")
        let runtime = setup.harness.runtime
        let git = setup.harness.repo.git
        var others: [AgentSession] = []
        for kind in AgentKind.allCases {
            others += try await runtime.spawn(in: setup.project, kind: kind, count: 1, git: git)
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
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        try await chat.send("CHAT-PROPOSE build alpha and beta", to: task, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let proposal = try #require(messages(setup, task).first { $0.kind == .proposal })
        #expect(proposal.status == .open && proposal.workflow == "feature-delivery" && proposal.title == "Add alpha and beta")
        #expect(try setup.harness.database.runs(taskId: task.id!).isEmpty)

        let run = try await chat.start(proposal, in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)

        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(leadAgent.runId == run.id)
        let runLeads = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id && $0.kind == .lead }
        #expect(runLeads.map(\.id) == [leadAgent.id])
        #expect(try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.kind == .lead }.count == 1)
        #expect(run.title == "Add alpha and beta")
        let input = try #require(try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }?.input)
        #expect(input.contains("Create alpha.txt and beta.txt, as agreed."))
        #expect(messages(setup, task).first { $0.id == proposal.id }?.status == .started)

        await #expect(throws: LeadChatError.proposalClosed) { try await chat.start(proposal, in: setup.project) }
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.proposal(RunProposal(workflow: "feature-delivery", title: "Again", brief: "x")), from: leadAgent.id!)
        }
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func theLeadRelaysToRunAgentsAndSeesTheRunStatus() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let run = try await chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let plan = try #require(try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }?.output
            .flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let runLeads = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id && $0.kind == .lead }
        let chatLead = try #require(runLeads.first { $0.taskId == task.id })
        let reviewer = try #require(runLeads.first { $0.taskId == nil })
        #expect(runLeads.count == 2)
        #expect(reviewer.readOnly && reviewer.costUSD > 0)
        let chatTranscript = try String(contentsOf: setup.harness.runtime.paths.transcript(chatLead.id!), encoding: .utf8)
        #expect(chatTranscript.contains("Each task gets its own builder"))
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
        let task = try await chat.createRequest("CHAT-PROPOSE alpha", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let proposal = try #require(messages(setup, task).first { $0.kind == .proposal })

        try chat.dismiss(proposal)
        let dismissed = try #require(messages(setup, task).first { $0.id == proposal.id })
        #expect(dismissed.status == .dismissed)
        await #expect(throws: LeadChatError.proposalClosed) { try await chat.start(dismissed, in: setup.project) }
    }

    func startedRun(_ setup: Setup, _ chat: LeadChat) async throws -> (Chat, Run) {
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let run = try await chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        return (task, run)
    }

    func endedRunWithAgents(_ setup: Setup, _ chat: LeadChat) async throws -> (Chat, Agent, [Agent]) {
        let (task, run) = try await startedRun(setup, chat)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
        let runtime = setup.harness.runtime
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        let builder = try await runtime.createRunAgent(
            in: setup.project, kind: .builder, runId: run.id!, runStepId: nil, task: "old work", git: setup.harness.repo.git
        )
        let spawned = try await runtime.spawn(
            in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Helper", spawnedBy: lead
        )
        return (task, lead, [builder.agent] + spawned.map(\.agent))
    }

    func propose(_ setup: Setup, from lead: Agent) async throws -> String {
        try await setup.driver.receive(.proposal(RunProposal(workflow: "feature-delivery", title: "Follow up", brief: "More work")), from: lead.id!)
    }

    func openProposal(_ setup: Setup, _ task: Chat) throws -> LeadMessage {
        try #require(messages(setup, task).last { $0.kind == .proposal && $0.status == .open })
    }

    func branches(_ setup: Setup) async throws -> String {
        try await setup.harness.repo.git.run(["branch", "--list"], in: setup.project.url)
    }

    @Test func startingAFollowUpRunClearsAgentsFromEarlierRunsButKeepsTheLeadAndBranches() async throws {
        let (setup, chat, _) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, lead, old) = try await endedRunWithAgents(setup, chat)
        let database = setup.harness.database
        #expect(Set(try database.previousRunAgents(taskId: task.id!).map(\.id)) == Set(old.map(\.id)))
        let worktrees = old.compactMap(\.worktreeURL)
        #expect(worktrees.count == 2 && worktrees.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let transcript = setup.harness.runtime.paths.transcript(lead.id!)
        #expect(FileManager.default.fileExists(atPath: transcript.path))

        let reply = try await propose(setup, from: lead)
        let names = old.map { database.displayName(of: $0) }
        #expect(reply.contains("Starting it clears 2 agents from earlier runs (\(names.joined(separator: ", "))). Tell the user in your reply."))

        let run = try await chat.start(try openProposal(setup, task), in: setup.project)

        let remaining = try database.agents(inProject: setup.project.id!).map(\.id)
        #expect(old.allSatisfy { !remaining.contains($0.id) })
        #expect(worktrees.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try database.leadAgent(taskId: task.id!)?.id == lead.id)
        #expect(FileManager.default.fileExists(atPath: transcript.path))
        let branchList = try await branches(setup)
        #expect(old.compactMap(\.branch).allSatisfy { branchList.contains($0) })
        let note = try #require(messages(setup, task).last { $0.kind == .note })
        #expect(note.text == "Cleared 2 agents from earlier runs: \(names.joined(separator: ", "))")
        #expect(try database.previousRunAgents(taskId: task.id!).allSatisfy { $0.runId == run.id || $0.id == lead.id })
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func dismissingAFollowUpProposalKeepsEarlierRunAgents() async throws {
        let (setup, chat, _) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, lead, old) = try await endedRunWithAgents(setup, chat)
        _ = try await propose(setup, from: lead)

        try chat.dismiss(try openProposal(setup, task))

        let remaining = try setup.harness.database.agents(inProject: setup.project.id!).map(\.id)
        #expect(old.allSatisfy { remaining.contains($0.id) })
        #expect(old.compactMap(\.worktreeURL).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!messages(setup, task).contains { $0.kind == .note && $0.text.hasPrefix("Cleared") })
    }

    @Test func aProposalWithoutEarlierRunAgentsMentionsNoClearing() async throws {
        let (setup, chat, _) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))

        let reply = try await propose(setup, from: lead)

        #expect(!reply.contains("clears"))
        #expect(try setup.harness.database.previousRunAgents(taskId: task.id!).isEmpty)
        let run = try await chat.start(try openProposal(setup, task), in: setup.project)
        #expect(!messages(setup, task).contains { $0.kind == .note && $0.text.hasPrefix("Cleared") })
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    func stored(_ setup: Setup, _ task: Chat) throws -> Chat {
        try #require(try setup.harness.database.task(id: task.id!))
    }

    @Test func closingAsResolvedOrClosedRecordsTheReason() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let finished = try await chat.createRequest("CHAT finished", in: setup.project)
        let abandoned = try await chat.createRequest("CHAT abandoned", in: setup.project)
        try await waitUntil { [finished, abandoned].allSatisfy { messages(setup, $0).contains { $0.kind == .lead } } }
        let doneAt = Date(timeIntervalSince1970: 2_000_000_000)
        let droppedAt = doneAt.addingTimeInterval(60)

        let done = try await chat.close(finished, as: .done, in: setup.project, git: setup.harness.repo.git, now: doneAt)
        let dropped = try await chat.close(abandoned, as: .dropped, in: setup.project, git: setup.harness.repo.git, now: droppedAt)

        #expect(done.isClosed && done.closeReason == .done && done.closedAt == doneAt && done.updatedAt == doneAt)
        #expect(dropped.isClosed && dropped.closeReason == .dropped && dropped.closedAt == droppedAt)
        #expect(try stored(setup, finished) == done)
        #expect(try stored(setup, abandoned) == dropped)
        #expect(RequestCloseReason.allCases.map(\.title) == ["Resolved", "Closed"])
    }

    @Test func closingIsRefusedWhileARunIsActiveAndARunEndingKeepsTheClosedState() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat)

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

    func branchExists(_ setup: Setup, _ branch: String) async throws -> Bool {
        try await setup.harness.repo.git.run(["branch", "--list", branch], in: setup.harness.repo.root).contains(branch)
    }

    func expectDeleted(_ setup: Setup, _ agentIDs: [Int64?]) throws {
        let remaining = try setup.harness.database.agents(inProject: setup.project.id!).map(\.id)
        for id in agentIDs {
            #expect(!remaining.contains(id))
            #expect(!FileManager.default.fileExists(atPath: setup.harness.runtime.paths.agentDirectory(id!).path))
        }
    }

    @Test func closingDeletesTheRequestsAgentsWorktreesAndBranchesAndNothingElse() async throws {
        for reason in RequestCloseReason.allCases {
            let (setup, chat, lead) = try await makeChat()
            defer { setup.harness.cleanUp() }
            let (task, run) = try await startedRun(setup, chat)
            try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
            let builder = try await setup.harness.runtime.createRunAgent(
                in: setup.project, kind: .builder, runId: run.id!, runStepId: nil,
                task: "Add alpha", git: setup.harness.repo.git
            )
            let builderWorktree = try #require(builder.agent.worktreeURL)
            let builderBranch = try #require(builder.agent.branch)
            let outsider = try await setup.harness.repo.manager.create(agent: "Outsider", slug: "keep")
            let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
            let leadSession = try #require(setup.harness.runtime.session(for: leadAgent))
            try await waitUntil { !leadSession.isRunning }
            let requestAgentIDs = try setup.harness.database.requestAgents(taskId: task.id!).map(\.id)
            #expect(requestAgentIDs.contains(leadAgent.id) && requestAgentIDs.contains(builder.id))
            let messagesBefore = messages(setup, task)

            let closed = try await chat.close(task, as: reason, in: setup.project, git: setup.harness.repo.git)

            #expect(closed.closeReason == reason)
            #expect(!leadSession.isRunning)
            try expectDeleted(setup, requestAgentIDs)
            #expect(try setup.harness.database.requestAgents(taskId: task.id!).isEmpty)
            #expect(try setup.harness.database.leadAgent(taskId: task.id!) == nil)
            #expect(chat.leadSession(for: closed) == nil)
            #expect(!FileManager.default.fileExists(atPath: builderWorktree.path))
            #expect(try await setup.harness.repo.manager.list().map(\.agent) == [outsider.agent])
            #expect(try await !branchExists(setup, builderBranch))
            #expect(try await branchExists(setup, try #require(outsider.branch)))
            #expect(messages(setup, task) == messagesBefore)
        }
    }

    @Test func launchCleanupDeletesAgentsOfRequestsClosedBeforeClosingDeletedThem() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
        let runtime = setup.harness.runtime
        let builder = try await runtime.createRunAgent(
            in: setup.project, kind: .builder, runId: run.id!, runStepId: nil,
            task: "Add alpha", git: setup.harness.repo.git
        )
        let builderBranch = try #require(builder.agent.branch)
        let worktree = try #require(try await setup.harness.repo.manager.list().first { $0.agent == builder.agent.worktreeURL?.lastPathComponent })
        try await setup.harness.repo.manager.remove(worktree, force: true, deleteBranch: false)
        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        try await waitUntil { runtime.session(for: leadAgent)?.isRunning == false }
        for agent in try setup.harness.database.requestAgents(taskId: task.id!) {
            runtime.session(for: agent)?.archive(detail: "Closing the request removed this agent’s worktree.", at: .now)
        }
        try setup.harness.database.setClosed(taskId: task.id!, reason: .done, at: .now)
        let closedAgentIDs = try setup.harness.database.requestAgents(taskId: task.id!).map(\.id)
        #expect(closedAgentIDs.count >= 2)
        #expect(try await branchExists(setup, builderBranch))

        let open = try await chat.createRequest("CHAT still going", in: setup.project)
        try await waitUntil { messages(setup, open).contains { $0.kind == .lead } }
        let openLead = try #require(try setup.harness.database.leadAgent(taskId: open.id!))

        await chat.deleteAgentsOfClosedRequests(in: setup.project, git: setup.harness.repo.git)

        try expectDeleted(setup, closedAgentIDs)
        #expect(try await !branchExists(setup, builderBranch))
        #expect(try setup.harness.database.leadAgent(taskId: open.id!)?.id == openLead.id)
        #expect(try stored(setup, task).closeReason == .done)

        await chat.deleteAgentsOfClosedRequests(in: setup.project, git: setup.harness.repo.git)
        #expect(try setup.harness.database.leadAgent(taskId: open.id!)?.id == openLead.id)
    }

    @Test func launchCleanupSkipsClosedRequestsWithAnActiveRun() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat)
        try setup.harness.database.setClosed(taskId: task.id!, reason: .dropped, at: .now)
        let agentIDs = try setup.harness.database.requestAgents(taskId: task.id!).map(\.id)

        await chat.deleteAgentsOfClosedRequests(in: setup.project, git: setup.harness.repo.git)

        #expect(try setup.harness.database.requestAgents(taskId: task.id!).map(\.id) == agentIDs)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func sendingToAClosedRequestReopensItWithANewLeadThatAnswers() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let firstLead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        let closed = try await chat.close(task, as: .done, in: setup.project, git: setup.harness.repo.git)
        #expect(try setup.harness.database.leadAgent(taskId: task.id!) == nil)
        let projectID = setup.project.id!
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: projectID)).closed.map(\.id) == [task.id])
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: projectID)).open.isEmpty)
        let launchesBefore = setup.harness.launches().count

        try await chat.send("CHAT one more thing", to: closed, in: setup.project)

        let reopened = try stored(setup, task)
        #expect(!reopened.isClosed && reopened.closeReason == nil)
        #expect(reopened.updatedAt > closed.updatedAt)
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: projectID)).open.map(\.id) == [task.id])
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }
        #expect(messages(setup, task).map(\.kind) == [.user, .lead, .user, .lead])
        #expect(setup.harness.launches().count == launchesBefore + 1)
        #expect(setup.harness.launches().last?.contains("--resume") == false)
        let leads = try setup.harness.database.agents(inProject: projectID).filter { $0.taskId == task.id }
        #expect(leads.count == 1)
        #expect(leads.first?.id != firstLead.id && leads.first?.kind == .lead)
    }

    @Test func startingAnOpenProposalOnAClosedRequestReopensIt() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let proposal = try #require(messages(setup, task).first { $0.kind == .proposal })
        try await chat.close(task, as: .dropped, in: setup.project, git: setup.harness.repo.git)

        let run = try await chat.start(proposal, in: setup.project)

        #expect(run.isActive && run.taskId == task.id)
        let reopened = try stored(setup, task)
        #expect(!reopened.isClosed && reopened.closeReason == nil)
        #expect(LeadRequest.partition(try setup.harness.database.leadRequests(projectId: setup.project.id!)).open.map(\.id) == [task.id])
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func closingAgainDeletesTheNewLeadAndIsSafe() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await startedRun(setup, chat)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
        let builder = try await setup.harness.runtime.createRunAgent(
            in: setup.project, kind: .builder, runId: run.id!, runStepId: nil,
            task: "Add alpha", git: setup.harness.repo.git
        )
        try await chat.close(task, as: .done, in: setup.project, git: setup.harness.repo.git)
        try expectDeleted(setup, [builder.id])

        try await chat.send("CHAT back again", to: try stored(setup, task), in: setup.project)
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }
        let secondLead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        try await chat.close(try stored(setup, task), as: .dropped, in: setup.project, git: setup.harness.repo.git)
        try expectDeleted(setup, [secondLead.id])

        let closedAgain = try await chat.close(try stored(setup, task), as: .done, in: setup.project, git: setup.harness.repo.git)

        #expect(closedAgain.closeReason == .done)
        #expect(try setup.harness.database.requestAgents(taskId: task.id!).isEmpty)
    }

    @Test func aRequestCanBeOnlyAttachments() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try StdinRecorder.install(in: setup.harness)
        let paste = ChatAttachment.pastedText(id: UUID(), index: 1, text: "CHAT crash log\n" + String(repeating: "frame\n", count: 30))
        let image = try ChatAttachment.image(data: try TestImages.encoded(width: 10, height: 10, as: .png), fileName: "shot.png")

        let task = try await chat.createRequest("", attachments: [paste, image], in: setup.project)
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
        let task = try await chat.createRequest("", attachments: [image], in: setup.project)
        #expect(task.title == "Image")
        #expect(task.body == "")

        try await waitUntil { chat.leadSession(for: task).map { !$0.isRunning && $0.agent.status == .idle } == true }
        try await chat.send("CHAT what about this one?", attachments: [image], to: task, in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }

        #expect(messages(setup, task).filter { $0.kind == .user }.map(\.text) == ["", "CHAT what about this one?"])
        let line = try #require(StdinRecorder.lines(in: setup.harness).last)
        #expect(StdinRecorder.imageBlocks(line).count == 1)
    }

    @Test func requestsNeedTextOrAttachments() async throws {
        let (setup, chat, lead) = try await makeChat()
        defer { setup.harness.cleanUp() }
        await #expect(throws: AgentError.emptyTask) { try await chat.createRequest("  ", in: setup.project) }
    }
}

@Suite struct RequestThreadTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    var task: Chat {
        Chat(id: 1, projectId: 1, title: "Add alpha", body: "Add alpha please", source: .chat, status: .running, createdAt: at(0), updatedAt: at(0))
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
        let answered = ChatRequest(id: 20, projectId: 1, runId: 7, kind: .question, title: "Q", status: .answered, response: "Yes", createdAt: at(4), resolvedAt: at(5))
        let open = ChatRequest(id: 21, projectId: 1, runId: 7, kind: .question, title: "Q2", createdAt: at(1))
        let timeline = RunTimeline(run: run, workflow: WorkflowDefinition(id: "w", name: "W", steps: []), steps: [], hold: nil)
        var withEntries = timeline
        withEntries.entries = [entry(30, status: .succeeded, ended: 4.5), entry(31, status: .running, ended: nil)]

        let thread = RequestThread(
            task: task, messages: [message(1, .user, 1), message(2, .lead, 2), message(3, .proposal, 2.5), message(4, .user, 6)],
            runs: [run], timelines: [7: withEntries], requests: [answered, open], heldRunIDs: [7]
        )

        #expect(thread.items.map(\.id) == ["message-1", "message-2", "message-3", "run-7", "step-30", "answer-20", "message-4", "question-21", "hold-7"])
        #expect(thread.items.suffix(2).allSatisfy { $0.isLive })
    }

    @Test func aProposalShowsAfterTheLeadsReplyFromTheSameTurn() {
        let thread = RequestThread(
            task: task, messages: [message(1, .user, 1), message(2, .proposal, 2), message(3, .lead, 3), message(4, .user, 4), message(5, .proposal, 5)],
            runs: [], timelines: [:], requests: [], heldRunIDs: []
        )
        #expect(thread.items.map(\.id) == ["message-1", "message-3", "message-2", "message-4", "message-5"])
    }

    @Test func permissionCardsStayOutOfTheThread() {
        let thread = RequestThread(
            task: task, messages: [message(1, .user, 1), message(2, .proposal, 2), message(3, .permission, 3), message(4, .lead, 4)],
            runs: [], timelines: [:], requests: [], heldRunIDs: []
        )
        #expect(thread.items.map(\.id) == ["message-1", "message-4", "message-2"])
    }

    @Test func requestsThatAreNotQuestionsOrHoldsShowAsNotices() {
        let run = Run(id: 7, projectId: 1, taskId: 1, workflow: "w", status: .waitingOnYou, startedAt: at(1))
        let holdRequest = ChatRequest(id: 40, projectId: 1, taskId: 1, runId: 7, kind: .approval, title: "Approve?", createdAt: at(2))
        let timeline = RunTimeline(run: run, workflow: WorkflowDefinition(id: "w", name: "W", steps: []), steps: [], hold: RunHold(reason: .approval, stepId: "approve", requestId: 40, message: "Approve?"), inbox: [holdRequest])
        let budget = ChatRequest(id: 41, projectId: 1, taskId: 1, kind: .budget, title: "Budget reached", createdAt: at(3))
        let oldNotice = ChatRequest(id: 42, projectId: 1, taskId: 1, kind: .notice, title: "Set up checks", status: .dismissed, createdAt: at(0.5))
        let permission = ChatRequest(id: 43, projectId: 1, taskId: 1, kind: .permission, title: "Run make?", createdAt: at(4))

        let thread = RequestThread(
            task: task, messages: [message(1, .user, 0)], runs: [run], timelines: [7: timeline],
            requests: [holdRequest, budget, oldNotice, permission], heldRunIDs: [7]
        )

        #expect(thread.items.map(\.id) == ["message-1", "notice-42", "run-7", "hold-7", "notice-41"])
        #expect(thread.items.last?.isLive == true)
        #expect(thread.items[1].isLive == false)
    }

    @Test func olderRequestsWithoutMessagesStartWithTheirBodyAndEndWithTheResult() {
        let run = Run(id: 8, projectId: 1, taskId: 1, workflow: "small-task", status: .succeeded, startedAt: at(1), endedAt: at(9))
        let thread = RequestThread(task: task, messages: [], runs: [run], timelines: [:], requests: [], heldRunIDs: [8])
        #expect(thread.items.map(\.id) == ["request-1", "run-8", "end-8"])
    }
}
