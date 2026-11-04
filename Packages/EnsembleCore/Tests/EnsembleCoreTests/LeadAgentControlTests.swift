import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct LeadAgentControlTests {
    typealias Setup = WorkflowDriverTests.Setup

    func makeLead() async throws -> (Setup, AgentSession) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let lead = try #require(try await setup.harness.runtime.spawn(in: setup.project, kind: .lead, count: 1, git: setup.harness.repo.git).first)
        return (setup, lead)
    }

    func agents(_ setup: Setup) throws -> [Agent] {
        try setup.harness.database.agents(inProject: setup.project.id!)
    }

    @Test func leadsGetAgentControlAndAWorktreeOnDemandWhileBuildersDoNot() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        let builder = try #require(try await setup.harness.runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git).first)

        #expect(setup.driver.tools(for: lead.agent) == HandoffTool.leadTools.union([.openWorktree, .readChat]))
        #expect(setup.driver.tools(for: builder.agent).isDisjoint(with: HandoffTool.leadTools.union([.openWorktree])))
        await #expect(throws: HandoffError.notAllowed("Only the Lead can manage agents.")) {
            try await setup.driver.receive(.listAgents, from: builder.id)
        }
    }

    @Test func aLeadSpawnsListsMessagesStopsAndDeletesAgents() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }

        let reply = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(agent: .builder, task: "Add alpha", name: "Helper", count: 2)), from: lead.id)
        let helpers = try agents(setup).filter { $0.kind == .builder }
        #expect(helpers.map(\.name) == ["Helper 1", "Helper 2"])
        #expect(helpers.allSatisfy { !$0.readOnly && $0.branch != nil && $0.worktreeURL.map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(reply == "Started Helper 1, Helper 2. Each agent’s report arrives as your next message when it finishes its turn. End your turn now.")

        let listing = try await setup.driver.receive(.listAgents, from: lead.id)
        #expect(listing.contains("- \(lead.agent.name) (you): lead"))
        #expect(listing.contains("- Helper 1: builder"))
        #expect(listing.contains("task: Add alpha"))

        let first = try #require(helpers.first)
        let firstSession = try #require(setup.harness.runtime.session(for: first))
        try await waitUntil { !firstSession.isRunning }
        let launchesBefore = setup.harness.launches().count
        #expect(try await setup.driver.receive(.agentMessage(agent: "helper 1", message: "Also add beta"), from: lead.id) == "Sent to Helper 1.")
        try await waitUntil { setup.harness.launches().count > launchesBefore }
        let transcript = try String(contentsOf: setup.harness.runtime.paths.transcript(first.id!), encoding: .utf8)
        #expect(transcript.contains("Message from \(lead.agent.name):\\n\\nAlso add beta"))

        try await waitUntil { !firstSession.isRunning }
        #expect(try await setup.driver.receive(.stopAgent("Helper 1"), from: lead.id) == "Stopping Helper 1.")
        #expect(firstSession.agent.status == .stopped)

        let worktree = try #require(first.worktreeURL)
        let branch = try #require(first.branch)
        #expect(try await setup.driver.receive(.deleteAgent("Helper 1", deleteBranch: true), from: lead.id) == "Deleted Helper 1 and its branch.")
        #expect(try agents(setup).map(\.name).contains("Helper 1") == false)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        let branches = try await setup.harness.repo.git.run(["branch", "--list", branch], in: setup.harness.repo.root)
        #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.deleteAgent(lead.agent.name, deleteBranch: false), from: lead.id)
        }
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.stopAgent("Nobody"), from: lead.id)
        }
    }

    @Test func aLeadSpawnsAgentsWithInstalledSkillsAndUnknownSkillsAreRejected() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        let skill = setup.harness.repo.root.appending(path: ".claude/skills/qa-review")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: qa-review\ndescription: Review like QA\n---\n\nCheck everything.".write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let reply = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(agent: .checker, task: "CHAT look around", name: "Reviewer", skills: ["qa-review"])), from: lead.id)
        #expect(reply.hasPrefix("Started Reviewer with qa-review."))
        let reviewer = try #require(try agents(setup).first { $0.name == "Reviewer" })
        #expect(reviewer.kind == .checker)
        #expect(reviewer.readOnly && reviewer.worktreePath == nil)
        #expect(reviewer.skills == ["qa-review"])
        #expect(try setup.harness.database.agent(id: reviewer.id!)?.skills == ["qa-review"])
        let prompt = try setup.harness.runtime.turnSetup(for: reviewer).systemPrompt
        #expect(prompt.contains("# Role: Checker"))
        #expect(prompt.contains("# Skills\n\nYour lead chose these skills"))
        #expect(prompt.contains("- qa-review"))
        #expect(try setup.harness.runtime.turnSetup(for: lead.agent).systemPrompt.contains("- `qa-review` (project): Review like QA"))

        await #expect(throws: AgentError.unknownSkills(["no-such-skill-zz"])) {
            try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(agent: .builder, task: "x", name: "Ghost", skills: ["no-such-skill-zz"])), from: lead.id)
        }
        #expect(try agents(setup).contains { $0.name == "Ghost" } == false)
        await #expect(throws: AgentError.unknownSkills(["no-such-skill-zz"])) {
            try await setup.driver.receive(.plan(Plan(summary: "s", tasks: [PlanTask(title: "t", skills: ["no-such-skill-zz"])])), from: lead.id)
        }
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.plan(Plan(summary: "s", tasks: [PlanTask(title: "t", agent: .checker)])), from: lead.id)
        }
        #expect(try await setup.driver.receive(.plan(Plan(summary: "s", tasks: [PlanTask(title: "t", skills: ["qa-review"])])), from: lead.id).hasPrefix("Plan received"))
    }

    func userMessages(_ session: AgentSession) -> [String] {
        session.transcript.entries.compactMap { entry -> String? in
            if case .user(let text) = entry.content { return text }
            return nil
        }
    }

    func spawnRunner(_ setup: Setup, from lead: AgentSession, task: String = "CHAT look around") async throws -> AgentSession {
        _ = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(agent: .builder, task: task, name: "Runner")), from: lead.id)
        let runner = try #require(try agents(setup).first { $0.name == "Runner" })
        return try #require(setup.harness.runtime.session(for: runner))
    }

    @Test func aSpawnedAgentsReportReachesTheLeadThatStartedIt() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }

        let runner = try await spawnRunner(setup, from: lead)
        #expect(runner.agent.spawnedById == lead.id)
        #expect(runner.agent.taskId == nil)
        try await waitUntil { userMessages(lead).contains("Report from Runner:\n\nThe repo only has a README.") }
        try await waitUntil { !runner.isRunning && !lead.isRunning }

        let launchesBefore = setup.harness.launches().count
        #expect(try await setup.driver.receive(.result("Ran the suite: 12 passed"), from: runner.id) == "Result recorded. End your turn now.")
        runner.send("CHAT run them again")
        try await waitUntil { userMessages(lead).contains("Report from Runner:\n\nRan the suite: 12 passed") }
        #expect(setup.harness.launches().count > launchesBefore)
    }

    @Test func aReportGoesToTheInboxWhenTheSpawnerIsGone() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }

        let runner = try await spawnRunner(setup, from: lead)
        try await waitUntil { userMessages(lead).contains { $0.hasPrefix("Report from Runner") } }
        try await waitUntil { !runner.isRunning && !lead.isRunning }
        try await setup.harness.runtime.delete(lead, in: setup.project, git: setup.harness.repo.git, deleteBranch: false)

        runner.send("CHAT anything else?")
        let projectId = try #require(setup.project.id)
        try await waitUntil { (try? setup.harness.database.openInboxItems(projectId: projectId))?.contains { $0.agentId == runner.id } == true }
        let item = try #require(try setup.harness.database.openInboxItems(projectId: projectId).first { $0.agentId == runner.id })
        #expect(item.kind == .notice)
        #expect(item.title == "Report from Runner")
        #expect(item.body == "The repo only has a README.")
    }

    @Test func aFailedSpawnedAgentReportsItsFailure() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        try setup.harness.setMode("crash")

        _ = try await spawnRunner(setup, from: lead)
        try await waitUntil { userMessages(lead).contains("Report from Runner:\n\nRunner failed: boom: invalid api key") }
    }

    @Test func aSpawnedAgentCanMessageAndAskOnlyItsSpawner() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        _ = try await setup.harness.runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Bystander")

        let runner = try await spawnRunner(setup, from: lead)
        let tools = setup.driver.tools(for: runner.agent)
        #expect(tools.isSuperset(of: [.messageAgent, .askHuman, .submitResult, .readChat]))
        #expect(tools.isDisjoint(with: [.proposeRun, .listAgents, .spawnAgent, .stopAgent, .deleteAgent]))
        try await setup.driver.ensureServer()
        let turn = try setup.harness.runtime.turnSetup(for: runner.agent)
        #expect(turn.systemPrompt.contains("# Reporting back\n\(lead.agent.name) started you."))
        try await waitUntil { userMessages(lead).contains { $0.hasPrefix("Report from Runner") } }
        try await waitUntil { !runner.isRunning && !lead.isRunning }

        #expect(try await setup.driver.receive(.agentMessage(agent: lead.agent.name.lowercased(), message: "Which suite?"), from: runner.id) == "Sent to \(lead.agent.name).")
        try await waitUntil { userMessages(lead).contains("Message from Runner, an agent you started:\n\nWhich suite?") }
        await #expect(throws: HandoffError.notAllowed("You can only message \(lead.agent.name), the agent that started you.")) {
            try await setup.driver.receive(.agentMessage(agent: "Bystander", message: "Hi"), from: runner.id)
        }
        try await waitUntil { !lead.isRunning }

        let reply = try await setup.driver.receive(.question("Should I run the slow tests?"), from: runner.id)
        #expect(reply.hasPrefix("Your question was sent to \(lead.agent.name)"))
        try await waitUntil { userMessages(lead).contains { $0.hasPrefix("A question from Runner") && $0.contains("Should I run the slow tests?") } }
        try await waitUntil { !lead.isRunning }
        let projectId = try #require(setup.project.id)
        #expect(try setup.harness.database.openInboxItems(projectId: projectId).isEmpty)

        let reportsBefore = userMessages(lead).filter { $0.hasPrefix("Report from Runner") }.count
        setup.driver.reportToSpawner(runner)
        #expect(!lead.isRunning && !lead.isQueued && lead.queuedMessages.isEmpty)
        #expect(userMessages(lead).filter { $0.hasPrefix("Report from Runner") }.count == reportsBefore)

        #expect(try await setup.driver.receive(.agentMessage(agent: "Runner", message: "Yes, run them"), from: lead.id) == "Sent to Runner.")
        try await waitUntil { userMessages(runner).contains("Message from \(lead.agent.name):\n\nYes, run them") }
    }

    @Test func readChatListsAgentsTheRequestsLeadSpawned() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        let now = Date()
        let task = try setup.harness.database.insert(ProjectTask(
            projectId: setup.project.id!, title: "Run the tests", body: "Please.", source: .chat, status: .incoming, createdAt: now, updatedAt: now
        ))
        let taskId = try #require(task.id)
        let lead = try setup.harness.runtime.createLeadAgent(in: setup.project, taskId: taskId)

        let runner = try await spawnRunner(setup, from: lead)
        #expect(runner.agent.taskId == nil)
        #expect(try setup.harness.database.leadAgent(taskId: taskId)?.id == lead.id)
        #expect(!setup.driver.tools(for: runner.agent).contains(.proposeRun))
        await #expect(throws: HandoffError.notAllowed("Only a request’s lead can propose runs.")) {
            try await setup.driver.receive(.proposal(RunProposal(workflow: "feature-delivery", title: "x", brief: "y")), from: runner.id)
        }
        try await waitUntil { userMessages(lead).contains { $0.hasPrefix("Report from Runner") } }

        let reader = ChatReader(database: setup.harness.database, paths: setup.harness.runtime.paths)
        let overview = try reader.read(ChatReadRequest(requestID: taskId))
        #expect(overview.contains("Lead: \(ChatReader.describe(lead.agent))"))
        #expect(overview.contains("Spawned agents: \(ChatReader.describe(runner.agent)), spawned by \(lead.agent.name)"))

        let transcript = try reader.read(ChatReadRequest(requestID: taskId, section: .transcript, agent: "runner"))
        #expect(transcript.hasPrefix("Transcript of \(ChatReader.describe(runner.agent)) in request \(taskId), spawned by \(lead.agent.name)"))
        #expect(transcript.contains("The repo only has a README."))
    }

    @Test func workingSessionsAreEveryRunningAgentOnTheRequestExceptTheChatLead() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        let database = setup.harness.database
        let runtime = setup.harness.runtime
        let now = Date()
        let task = try database.insert(ProjectTask(
            projectId: setup.project.id!, title: "Run the tests", body: "Please.", source: .chat, status: .incoming, createdAt: now, updatedAt: now
        ))
        let lead = try runtime.createLeadAgent(in: setup.project, taskId: task.id!)
        let chat = LeadChat(runtime: runtime, engine: setup.engine, driver: setup.driver)
        try setup.harness.setMode("slow")
        #expect(chat.workingSessions(for: task).isEmpty)

        let runner = try await spawnRunner(setup, from: lead)
        let bystander = try #require(try await runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Bystander").first)
        bystander.send("CHAT look around")
        lead.send("CHAT keep going")
        try await waitUntil { runner.isRunning && bystander.isRunning && (lead.isRunning || lead.isQueued) }
        #expect(chat.workingSessions(for: task).map(\.id) == [runner.id])

        let run = try database.insert(Run(projectId: setup.project.id!, taskId: task.id!, workflow: "feature-delivery", status: .running, startedAt: now), state: RunEngineState())
        runner.attach(toRun: try #require(run.id))
        #expect(chat.workingSessions(for: task).map(\.id) == [runner.id])

        let builder = try #require(try await runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Run Builder").first)
        builder.attach(toRun: try #require(run.id))
        #expect(chat.workingSessions(for: task).map(\.id) == [runner.id])
        builder.send("CHAT build it")
        try await waitUntil { builder.isRunning || builder.isQueued }
        #expect(chat.workingSessions(for: task).map(\.id) == [runner.id, builder.id].sorted())

        runner.stop()
        builder.stop()
        bystander.stop()
        try await waitUntil { !runner.isRunning && !runner.isQueued && !builder.isRunning && !builder.isQueued }
        #expect(chat.workingSessions(for: task).isEmpty)
    }

    @Test func theSpawnedAgentsMigrationAddsTheSpawnerColumn() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in try db.columns(in: "agent").map(\.name) }
        #expect(columns.contains("spawnedById"))
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/repo"))
        let lead = try database.insert(Agent(projectId: project.id!, role: "tech-lead", name: "Lead", status: .idle, createdAt: .now, updatedAt: .now))
        let spawned = try database.insert(Agent(projectId: project.id!, role: "claude-code", name: "Runner", status: .idle, spawnedById: lead.id, createdAt: .now, updatedAt: .now))
        #expect(try database.agent(id: spawned.id!)?.spawnedById == lead.id)
    }

    @Test func aLeadOpensItsOwnWorktreeAndContinuesThereWithWriteAccess() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        #expect(lead.agent.readOnly && lead.agent.worktreePath == nil)

        let launchesBefore = setup.harness.launches().count
        let reply = try await setup.driver.receive(.openWorktree, from: lead.id)
        let worktree = try #require(lead.agent.worktreeURL)
        #expect(!lead.agent.readOnly)
        #expect(lead.agent.branch != nil)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(reply.hasPrefix("Worktree ready at \(worktree.path)"))
        #expect(!setup.driver.tools(for: lead.agent).contains(.openWorktree))
        #expect(setup.driver.tools(for: lead.agent).isSuperset(of: HandoffTool.leadTools))

        try await waitUntil { setup.harness.launches().count > launchesBefore }
        let turn = try setup.harness.runtime.turnSetup(for: lead.agent)
        #expect(!turn.readOnly)
        #expect(realPath(of: turn.directory) == realPath(of: worktree))
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.openWorktree, from: lead.id)
        }
    }

    func makeNumberedLeads(_ count: Int) async throws -> (Setup, [AgentSession]) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let leads = try await setup.harness.runtime.spawn(in: setup.project, kind: .lead, count: count, git: setup.harness.repo.git)
        return (setup, leads)
    }

    @Test func numberedLeadsAreToldTheirKindNameWhileBuildersKeepTheirNumbers() async throws {
        let (setup, leads) = try await makeNumberedLeads(2)
        defer { setup.harness.cleanUp() }
        let lead = try #require(leads.first)
        #expect(lead.agent.name == "Lead 1")
        let builders = try await setup.harness.runtime.spawn(in: setup.project, kind: .builder, count: 2, git: setup.harness.repo.git)
        let builder = try #require(builders.first)
        #expect(builder.agent.name == "Builder 1")

        let leadPrompt = try setup.harness.runtime.turnSetup(for: lead.agent).systemPrompt
        #expect(leadPrompt.contains("You are Lead, "))
        #expect(!leadPrompt.contains("Lead 1"))
        #expect(try setup.harness.runtime.turnSetup(for: builder.agent).systemPrompt.contains("You are Builder 1, "))
    }

    @Test func messagesAndReportsUseTheLeadsKindName() async throws {
        let (setup, leads) = try await makeNumberedLeads(2)
        defer { setup.harness.cleanUp() }
        let lead = try #require(leads.first)

        let runner = try await spawnRunner(setup, from: lead)
        try await waitUntil { userMessages(lead).contains("Report from Runner:\n\nThe repo only has a README.") }
        try await waitUntil { !runner.isRunning && !lead.isRunning }
        #expect(try await setup.driver.receive(.agentMessage(agent: "Lead 1", message: "Which suite?"), from: runner.id) == "Sent to Lead.")
        try await waitUntil { userMessages(lead).contains("Message from Runner, an agent you started:\n\nWhich suite?") }
        #expect(try await setup.driver.receive(.agentMessage(agent: "Runner", message: "The fast one"), from: lead.id) == "Sent to Runner.")
        try await waitUntil { userMessages(runner).contains("Message from Lead:\n\nThe fast one") }
    }

    @Test func messageAgentFindsALeadByKindNameAndRejectsAnAmbiguousOne() async throws {
        let (setup, leads) = try await makeNumberedLeads(3)
        defer { setup.harness.cleanUp() }
        let caller = try #require(leads.first)
        let other = try #require(leads.last)

        await #expect(throws: HandoffError.notAllowed("Several agents are called “Lead”: Lead 2, Lead 3. Use one of those exact names.")) {
            try await setup.driver.receive(.agentMessage(agent: "lead", message: "Hi"), from: caller.id)
        }
        let listing = try await setup.driver.receive(.listAgents, from: caller.id)
        #expect(listing.contains("- Lead (Lead 1) (you): lead"))
        #expect(listing.contains("- Lead (Lead 2): lead"))
        #expect(listing.contains("- Lead (Lead 3): lead"))

        #expect(try await setup.driver.receive(.agentMessage(agent: "Lead 3", message: "Hi"), from: caller.id) == "Sent to Lead.")
        try await waitUntil { userMessages(other).contains("Message from Lead:\n\nHi") }
        try await waitUntil { !other.isRunning }

        let middle = try #require(setup.harness.runtime.session(for: leads[1].agent))
        try await setup.harness.runtime.delete(middle, in: setup.project, git: setup.harness.repo.git, deleteBranch: false)
        #expect(try await setup.driver.receive(.agentMessage(agent: "Lead", message: "Again"), from: caller.id) == "Sent to Lead.")
        try await waitUntil { userMessages(other).contains("Message from Lead:\n\nAgain") }
    }

    @Test func aReadOnlyLeadIsToldItCanOpenAWorktree() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        #expect(ClaudeLaunch.readOnlySystemPrompt(agentName: "Lead", directory: directory, canOpenWorktree: true).contains(HandoffTool.openWorktree.qualifiedName))
        #expect(!ClaudeLaunch.readOnlySystemPrompt(agentName: "Reviewer", directory: directory).contains(HandoffTool.openWorktree.qualifiedName))
    }

    @Test func everyBasePromptTellsTheAgentToServeItself() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        #expect(ClaudeLaunch.systemPrompt(agentName: "Builder", worktree: directory, branch: "crew/builder").contains(ClaudeLaunch.selfServiceRule))
        #expect(ClaudeLaunch.systemPrompt(agentName: "Builder", worktree: directory, branch: nil).contains(ClaudeLaunch.selfServiceRule))
        #expect(ClaudeLaunch.readOnlySystemPrompt(agentName: "Lead", directory: directory, canOpenWorktree: true).contains(ClaudeLaunch.selfServiceRule))
        #expect(ClaudeLaunch.readOnlySystemPrompt(agentName: "Reviewer", directory: directory).contains(ClaudeLaunch.selfServiceRule))
    }

    @Test func buildersCheckersAndLeadsAreToldToServeThemselves() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        let builder = try #require(try await setup.harness.runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git).first)
        let checker = try #require(try await setup.harness.runtime.spawn(in: setup.project, kind: .checker, count: 1, git: setup.harness.repo.git).first)
        for agent in [builder.agent, checker.agent, lead.agent] {
            #expect(try setup.harness.runtime.turnSetup(for: agent).systemPrompt.contains(ClaudeLaunch.selfServiceRule), "\(agent.name)")
        }
    }

    @Test func newToolsDecodeTheirArguments() throws {
        #expect(try HandoffTool.listAgents.decode(.object([:])) == .listAgents)
        #expect(try HandoffTool.openWorktree.decode(.object([:])) == .openWorktree)
        #expect(try HandoffTool.stopAgent.decode(.object(["agent": .string("Ada")])) == .stopAgent("Ada"))
        #expect(try HandoffTool.deleteAgent.decode(.object(["agent": .string("Ada")])) == .deleteAgent("Ada", deleteBranch: false))
        #expect(try HandoffTool.deleteAgent.decode(.object(["agent": .string("Ada"), "delete_branch": .bool(true)])) == .deleteAgent("Ada", deleteBranch: true))
        #expect(try HandoffTool.spawnAgent.decode(.object(["agent": .string("builder"), "task": .string("Build it"), "count": .number(0)]))
            == .spawnAgent(AgentSpawnRequest(agent: .builder, task: "Build it", count: 1)))
        #expect(try HandoffTool.spawnAgent.decode(.object(["agent": .string("checker"), "task": .string("Review it"), "skills": .array([.string("qa-review"), .string(" ")])]))
            == .spawnAgent(AgentSpawnRequest(agent: .checker, task: "Review it", skills: ["qa-review"])))
        #expect(throws: HandoffError.missing("task")) {
            try HandoffTool.spawnAgent.decode(.object(["agent": .string("builder"), "task": .string(" ")]))
        }
        #expect(throws: HandoffError.missing("agent")) {
            try HandoffTool.spawnAgent.decode(.object(["role": .string("claude-code"), "task": .string("Build it")]))
        }
        #expect(throws: HandoffError.self) {
            try HandoffTool.spawnAgent.decode(.object(["agent": .string("lead"), "task": .string("Build it")]))
        }
        #expect(throws: HandoffError.missing("agent")) { try HandoffTool.stopAgent.decode(.object([:])) }
    }
}
