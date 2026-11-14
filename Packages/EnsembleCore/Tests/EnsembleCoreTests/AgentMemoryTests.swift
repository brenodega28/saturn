import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct AgentMemoryStoreTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-memory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func writesReadsCountsAndClearsAMemoryFile() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let memory = AgentMemory(repository: repository, agentName: "Tech Lead")

        #expect(memory.url.path.hasSuffix(".ensemble/memory/tech-lead.md"))
        #expect(memory.read().isEmpty)
        #expect(memory.noteCount == 0)
        #expect(memory.promptSection() == nil)

        try memory.write("# Notes\n- Orders live in orders/\n* Use pytest -q\n\nSome prose that is not a note.\n-   \n")
        #expect(memory.exists)
        #expect(memory.notes == ["Orders live in orders/", "Use pytest -q"])
        #expect(memory.noteCount == 2)
        #expect(memory.estimatedTokens == AgentMemory.estimatedTokens(in: memory.read()))
        #expect(memory.estimatedTokens > 10)

        try memory.forgetNote(at: 0)
        #expect(memory.notes == ["Use pytest -q"])
        #expect(memory.read().contains("# Notes"))

        try memory.clear()
        #expect(!memory.exists)
        #expect(memory.noteCount == 0)
        try memory.clear()
    }

    @Test func memoryFolderIsGitIgnoredWithoutDuplicatingEntries() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let ensemble = ProjectConfig.directory(in: repository)
        try FileManager.default.createDirectory(at: ensemble, withIntermediateDirectories: true)
        try "local.yaml".write(to: ensemble.appending(path: ".gitignore"), atomically: true, encoding: .utf8)

        try AgentMemory(repository: repository, agentName: "QA").write("- one")
        try AgentMemory(repository: repository, agentName: "Dev").write("- two")

        let ignore = try String(contentsOf: ensemble.appending(path: ".gitignore"), encoding: .utf8)
        #expect(ignore.components(separatedBy: "\n").filter { !$0.isEmpty } == ["local.yaml", "memory/"])
    }

    @Test func promptSectionIsTruncatedSensibly() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let memory = AgentMemory(repository: repository, agentName: "QA")
        let lines = (1...200).map { "- Note number \($0) about something durable" }
        try memory.write(lines.joined(separator: "\n"))

        let section = try #require(memory.promptSection(characterLimit: 500))
        #expect(section.hasPrefix("## Your memory"))
        #expect(section.contains("- Note number 1 about"))
        #expect(!section.contains("- Note number 200 about"))
        #expect(section.contains("more lines cut"))
        #expect(section.count < 900)
    }

    @Test func memoryReplyIsExtractedFromTags() {
        #expect(PinnedMemoryUpdater.memoryReply(in: "Sure.\n<memory>\n- a\n- b\n</memory>\nDone") == "- a\n- b")
        #expect(PinnedMemoryUpdater.memoryReply(in: "no tags here") == nil)
    }
}

@MainActor
@Suite(.serialized) struct MemoryPromptTests {
    @Test func pinnedAgentsGetTheirMemoryInTheSystemPrompt() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let pinned = try #require(try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, pinned: true, name: "Keeper").first)
        let unpinned = try #require(try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, name: "Drifter").first)
        try AgentMemory(repository: harness.repo.root, agentName: "Keeper").write("- Payments live in orders/")
        try AgentMemory(repository: harness.repo.root, agentName: "Drifter").write("- Should never be loaded")

        let setup = try harness.runtime.turnSetup(for: pinned.agent)
        #expect(setup.systemPrompt.contains("## Your memory"))
        #expect(setup.systemPrompt.contains("- Payments live in orders/"))
        #expect(!setup.extraAllowedTools.contains { $0.contains("memory") })

        let other = try harness.runtime.turnSetup(for: unpinned.agent)
        #expect(!other.systemPrompt.contains("## Your memory"))
    }

    @Test func memoryTurnsMayWriteOnlyTheMemoryFile() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let session = try #require(try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, pinned: true, name: "Keeper").first)
        harness.runtime.memoryUpdateAgents.insert(session.id)

        let setup = try harness.runtime.turnSetup(for: session.agent)
        let memory = AgentMemory(repository: harness.repo.root, agentName: "Keeper")
        let realFile = "/" + realPath(of: AgentMemory.directory(in: harness.repo.root)) + "/keeper.md"
        #expect(setup.extraAllowedTools.contains("Write(\(realFile))"))
        #expect(setup.extraAllowedTools.contains("Edit(\(realFile))"))
        #expect(!setup.extraAllowedTools.contains { $0.hasPrefix("Bash") })
        #expect(setup.additionalDirectories.map { realPath(of: $0) } == [realPath(of: AgentMemory.directory(in: harness.repo.root))])
        #expect(memory.url.lastPathComponent == "keeper.md")

        harness.runtime.memoryUpdateAgents.remove(session.id)
        session.setPinned(false)
        harness.runtime.memoryUpdateAgents.insert(session.id)
        let unpinned = try harness.runtime.turnSetup(for: session.agent)
        #expect(!unpinned.extraAllowedTools.contains { $0.contains("keeper.md") })
    }
}

@MainActor
@Suite(.serialized) struct PinnedMemoryRunTests {
    struct Setup {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let engine: RunEngine
        let updater: PinnedMemoryUpdater
        let project: Project
        let config: ProjectConfig
    }

    func makeSetup() async throws -> Setup {
        let harness = try await AgentHarness.make(mode: "workflow")
        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        try LegacyWorkflows.install(repository: harness.repo.root)
        var feature = try #require(ProjectConfigLoader.load(repository: harness.repo.root).workflow("feature-delivery"))
        feature.end = WorkflowEnd(action: .merge, cleanUpWorktrees: true)
        try ProjectConfigLoader.write(feature, repository: harness.repo.root)
        try await harness.repo.git.run(["add", ".ensemble"], in: harness.repo.root)
        try await harness.repo.git.run(["commit", "-m", "Add Ensemble config"], in: harness.repo.root)

        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.pollInterval = .milliseconds(20)
        let updater = PinnedMemoryUpdater(runtime: harness.runtime)
        updater.pollInterval = .milliseconds(20)
        updater.turnTimeout = .seconds(30)
        driver.memoryUpdater = updater
        let engine = RunEngine(database: harness.database, driver: driver)
        updater.observe(engine)
        let project = try #require(try harness.database.project(id: harness.project.id!))
        return Setup(harness: harness, driver: driver, engine: engine, updater: updater, project: project, config: ProjectConfigLoader.load(repository: harness.repo.root))
    }

    func startRun(_ setup: Setup) throws -> Run {
        let now = Date()
        let task = try setup.harness.database.insert(Chat(
            projectId: setup.project.id!, title: "Add alpha and beta", body: "Two files, please.", source: .chat,
            status: .incoming, createdAt: now, updatedAt: now
        ))
        return try setup.engine.start(task: task, workflow: try #require(setup.config.workflow("feature-delivery")), project: setup.project)
    }

    func session(_ setup: Setup, where predicate: (Agent) -> Bool) throws -> AgentSession {
        let agent = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first(where: predicate))
        return try #require(setup.harness.runtime.session(for: agent))
    }

    @Test func pinnedAgentsUpdateTheirMemoryWhenARunSucceeds() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitUntil(timeout: .seconds(30)) { setup.engine.holds[run.id!]?.reason == .planApproval }
        let lead = try session(setup) { $0.role == "lead" }
        lead.setPinned(true)

        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await waitUntil(timeout: .seconds(60)) { setup.engine.holds[run.id!]?.reason == .approval }
        let builder = try session(setup) { $0.planTaskId != nil && $0.task == "Add alpha" }
        builder.setPinned(true)
        let unpinnedBuilder = try session(setup) { $0.planTaskId != nil && $0.task == "Add beta" }

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(60)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }

        let builderMemory = AgentMemory(repository: setup.harness.repo.root, agentName: builder.agent.name)
        #expect(builderMemory.notes == ["Run the tests with make test", "Keep commits small"])
        let leadMemory = AgentMemory(repository: setup.harness.repo.root, agentName: lead.agent.name)
        #expect(leadMemory.notes == ["Flaky checkout specs live in spec/checkout", "The user wants short summaries"])
        #expect(!AgentMemory(repository: setup.harness.repo.root, agentName: unpinnedBuilder.agent.name).exists)

        let realFile = "/" + realPath(of: AgentMemory.directory(in: setup.harness.repo.root)) + "/" + builderMemory.url.lastPathComponent
        let memoryLaunches = setup.harness.launches().filter { $0.contains("Write(\(realFile))") }
        #expect(memoryLaunches.count == 1)
        let memoryDirectory = realPath(of: AgentMemory.directory(in: setup.harness.repo.root))
        #expect(setup.harness.launches().filter { $0.contains("--add-dir \(memoryDirectory) ") }.count == 2)
        #expect(setup.harness.runtime.memoryUpdateAgents.isEmpty)

        let status = try await setup.harness.repo.git.run(["status", "--porcelain", "--ignored"], in: setup.harness.repo.root)
        #expect(status.contains("!! .ensemble/memory/"))
        let main = try await setup.harness.repo.git.run(["ls-tree", "-r", "--name-only", "main"], in: setup.harness.repo.root)
        #expect(!main.contains("memory/"))

        await setup.updater.updateMemories(after: try #require(try setup.harness.database.run(id: run.id!)))
        #expect(setup.harness.launches().filter { $0.contains("Write(\(realFile))") }.count == 1)
    }

    @Test func pinnedAgentsUpdateTheirMemoryWhenARunFails() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitUntil(timeout: .seconds(30)) { setup.engine.holds[run.id!]?.reason == .planApproval }
        let lead = try session(setup) { $0.role == "lead" }
        lead.setPinned(true)

        setup.driver.gitProvider = { nil }
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await waitUntil(timeout: .seconds(30)) {
            setup.engine.holds[run.id!]?.reason == .stepFailed || (try? setup.harness.database.run(id: run.id!))??.status == .failed
        }
        if setup.engine.holds[run.id!]?.reason == .stepFailed {
            try setup.engine.resolveFailure(run, retry: false)
        }
        #expect((try setup.harness.database.run(id: run.id!))?.status == .failed)

        let leadMemory = AgentMemory(repository: setup.harness.repo.root, agentName: lead.agent.name)
        try await waitUntil(timeout: .seconds(30)) { leadMemory.noteCount == 2 }
        #expect(leadMemory.notes.first == "Flaky checkout specs live in spec/checkout")
    }
}
