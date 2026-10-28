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
        #expect(reply == "Started Helper 1, Helper 2. Check on them with list_agents.")
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
