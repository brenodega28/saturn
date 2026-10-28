import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct LeadAgentControlTests {
    typealias Setup = WorkflowDriverTests.Setup

    func makeLead() async throws -> (Setup, AgentSession) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let role = try #require(setup.config.role("tech-lead"))
        let lead = try #require(try await setup.harness.runtime.spawn(in: setup.project, role: role, count: 1, config: setup.config, git: setup.harness.repo.git).first)
        return (setup, lead)
    }

    func agents(_ setup: Setup) throws -> [Agent] {
        try setup.harness.database.agents(inProject: setup.project.id!)
    }

    @Test func leadsGetAgentControlAndAWorktreeOnDemandWhileBuildersDoNot() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }
        let builderRole = try #require(setup.config.role("claude-code"))
        let builder = try #require(try await setup.harness.runtime.spawn(in: setup.project, role: builderRole, count: 1, config: setup.config, git: setup.harness.repo.git).first)

        #expect(setup.driver.tools(for: lead.agent) == HandoffTool.leadTools.union([.openWorktree, .readChat]))
        #expect(setup.driver.tools(for: builder.agent).isDisjoint(with: HandoffTool.leadTools.union([.openWorktree])))
        await #expect(throws: HandoffError.notAllowed("Only lead roles can manage agents.")) {
            try await setup.driver.receive(.listAgents, from: builder.id)
        }
    }

    @Test func aLeadSpawnsListsMessagesStopsAndDeletesAgents() async throws {
        let (setup, lead) = try await makeLead()
        defer { setup.harness.cleanUp() }

        let reply = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(role: "claude-code", task: "Add alpha", name: "Helper", count: 2)), from: lead.id)
        let helpers = try agents(setup).filter { $0.role == "claude-code" }
        #expect(helpers.map(\.name) == ["Helper 1", "Helper 2"])
        #expect(helpers.allSatisfy { !$0.readOnly && $0.branch != nil && $0.worktreeURL.map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(reply == "Started Helper 1, Helper 2. Each agent’s report arrives as your next message when it finishes its turn. End your turn now.")
        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(role: "nobody", task: "x")), from: lead.id)
        }

        let listing = try await setup.driver.receive(.listAgents, from: lead.id)
        #expect(listing.contains("- \(lead.agent.name) (you): role tech-lead"))
        #expect(listing.contains("- Helper 1: role claude-code"))
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

    func userMessages(_ session: AgentSession) -> [String] {
        session.transcript.entries.compactMap { entry -> String? in
            if case .user(let text) = entry.content { return text }
            return nil
        }
    }

    func spawnRunner(_ setup: Setup, from lead: AgentSession, task: String = "CHAT look around") async throws -> AgentSession {
        _ = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(role: "claude-code", task: task, name: "Runner")), from: lead.id)
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
        let builderRole = try #require(setup.config.role("claude-code"))
        _ = try await setup.harness.runtime.spawn(in: setup.project, role: builderRole, count: 1, config: setup.config, git: setup.harness.repo.git, name: "Bystander")

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
        let lead = try setup.harness.runtime.createLeadAgent(in: setup.project, role: try #require(setup.config.role("tech-lead")), taskId: taskId)

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

    @Test func aReadOnlyLeadIsToldItCanOpenAWorktree() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        #expect(ClaudeLaunch.readOnlySystemPrompt(agentName: "Lead", directory: directory, canOpenWorktree: true).contains(HandoffTool.openWorktree.qualifiedName))
        #expect(!ClaudeLaunch.readOnlySystemPrompt(agentName: "Reviewer", directory: directory).contains(HandoffTool.openWorktree.qualifiedName))
    }

    @Test func newToolsDecodeTheirArguments() throws {
        #expect(try HandoffTool.listAgents.decode(.object([:])) == .listAgents)
        #expect(try HandoffTool.openWorktree.decode(.object([:])) == .openWorktree)
        #expect(try HandoffTool.stopAgent.decode(.object(["agent": .string("Ada")])) == .stopAgent("Ada"))
        #expect(try HandoffTool.deleteAgent.decode(.object(["agent": .string("Ada")])) == .deleteAgent("Ada", deleteBranch: false))
        #expect(try HandoffTool.deleteAgent.decode(.object(["agent": .string("Ada"), "delete_branch": .bool(true)])) == .deleteAgent("Ada", deleteBranch: true))
        #expect(try HandoffTool.spawnAgent.decode(.object(["role": .string("claude-code"), "task": .string("Build it"), "count": .number(0)]))
            == .spawnAgent(AgentSpawnRequest(role: "claude-code", task: "Build it", count: 1)))
        #expect(throws: HandoffError.missing("task")) {
            try HandoffTool.spawnAgent.decode(.object(["role": .string("claude-code"), "task": .string(" ")]))
        }
        #expect(throws: HandoffError.missing("agent")) { try HandoffTool.stopAgent.decode(.object([:])) }
    }
}
