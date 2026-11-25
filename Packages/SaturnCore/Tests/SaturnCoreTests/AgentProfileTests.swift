import Foundation
import Testing
import Yams
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct AgentProfileTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "saturn-agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: ".saturn/agents"), withIntermediateDirectories: true)
        return root
    }

    func write(_ text: String, to path: String, in repository: URL) throws {
        let url = repository.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let djangoBuilder = """
    name: Django Builder
    kind: builder
    model: opus
    description: Builds the Django backend.
    instructions: Follow the service layer pattern in api/services.
    skills: [django-developer]
    """

    @Test func profilesLoadIntoTheProjectConfig() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write(Self.djangoBuilder, to: ".saturn/agents/django-builder.yaml", in: repository)
        try write("name: UI Reviewer\nkind: checker\ndescription: Reviews the React UI.\ninstructions: Check accessibility.\n", to: ".saturn/agents/ui-reviewer.yaml", in: repository)

        let config = ProjectConfigLoader.load(repository: repository)
        #expect(config.issues.isEmpty)
        #expect(config.agents.map(\.id) == ["django-builder", "ui-reviewer"])
        let builder = try #require(config.agentProfile("django-builder"))
        #expect(builder.name == "Django Builder" && builder.kind == .builder && builder.model == "opus")
        #expect(builder.description == "Builds the Django backend.")
        #expect(builder.instructions == "Follow the service layer pattern in api/services.")
        #expect(builder.skills == ["django-developer"])
        #expect(config.agentProfile("ui-reviewer")?.kind == .checker)
        #expect(config.agentProfile("ui-reviewer")?.model == nil)
    }

    @Test func aMalformedProfileIsAConfigIssueNotACrash() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write(Self.djangoBuilder, to: ".saturn/agents/django-builder.yaml", in: repository)
        try write("name: Boss\nkind: lead\n", to: ".saturn/agents/boss.yaml", in: repository)
        try write("kind: builder\n", to: ".saturn/agents/nameless.yaml", in: repository)
        try write("{{ not yaml", to: ".saturn/agents/garbage.yaml", in: repository)
        try write("name: Builder\nkind: builder\n", to: ".saturn/agents/builder.yaml", in: repository)
        try write("name: Shouty\nkind: checker\nmodel: gpt-9\n", to: ".saturn/agents/Shouty_Agent.yaml", in: repository)

        let config = ProjectConfigLoader.load(repository: repository)
        let files = Set(config.issues.map(\.file))
        #expect(files.isSuperset(of: [".saturn/agents/boss.yaml", ".saturn/agents/nameless.yaml", ".saturn/agents/garbage.yaml", ".saturn/agents/builder.yaml", ".saturn/agents/Shouty_Agent.yaml"]))
        #expect(!files.contains(".saturn/agents/django-builder.yaml"))
        let messages = config.issues.map { "\($0.file): \($0.message)" }
        #expect(messages.contains { $0.hasPrefix(".saturn/agents/boss.yaml") && $0.contains("kind must be builder or checker") })
        #expect(messages.contains(".saturn/agents/builder.yaml: “builder” is reserved for the built-in agent kinds"))
        #expect(messages.contains(".saturn/agents/Shouty_Agent.yaml: “Shouty_Agent” must be lowercase kebab-case, like django-builder"))
        #expect(messages.contains(".saturn/agents/Shouty_Agent.yaml: model “gpt-9” isn’t a known model"))
        #expect(config.agentProfile("django-builder") != nil)
    }

    @Test func aWorkflowStepNamesAProfileAndResolvesToIt() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write(Self.djangoBuilder, to: ".saturn/agents/django-builder.yaml", in: repository)
        try write("""
        name: Django
        steps:
          - id: build
            type: agent
            agent: django-builder
            instructions: Build the task.
            next: review
          - id: review
            type: agent
            agent: ghost-reviewer
            model: sonnet
            routes:
              approved: end
              changes_requested: build
        """, to: ".saturn/workflows/django.yaml", in: repository)

        let config = ProjectConfigLoader.load(repository: repository)
        let workflow = try #require(config.workflow("django"))
        let build = try #require(workflow.step("build"))
        #expect(build.agent == nil && build.profile == "django-builder")
        let resolved = try #require(config.resolve(build))
        #expect(resolved.kind == .builder && resolved.model == "opus")
        #expect(resolved.instructions == "Follow the service layer pattern in api/services.\n\nBuild the task.")
        #expect(resolved.skills == ["django-developer"])
        #expect(config.issues.map(\.message) == ["steps.review: agent “ghost-reviewer” isn’t lead, builder, checker or an agent profile in .saturn/agents"])

        let yaml = try ProjectConfigLoader.encodeYAML(workflow)
        #expect(yaml.contains("agent: django-builder"))
        let decoded = try YAMLDecoder().decode(WorkflowDefinition.self, from: yaml)
        #expect(decoded.step("build")?.profile == "django-builder")
        #expect(decoded.step("review")?.model == "sonnet")
    }

    @Test func choosingABuiltInAgentInTheInspectorReplacesTheProfile() throws {
        var step = WorkflowStep(id: "build", type: .agent, profile: "django-builder")
        #expect(step.agentChoice == "django-builder")

        step.agentChoice = "checker"
        #expect(step.agent == .checker && step.profile == nil)
        #expect(try ProjectConfigLoader.encodeYAML(step).contains("agent: checker"))

        step.agentChoice = "ui-reviewer"
        #expect(step.agent == nil && step.profile == "ui-reviewer")
        #expect(try ProjectConfigLoader.encodeYAML(step).contains("agent: ui-reviewer"))

        step.agent = .builder
        #expect(step.profile == nil)
        #expect(try ProjectConfigLoader.encodeYAML(step).contains("agent: builder"))

        step.agentChoice = nil
        #expect(step.agent == nil && step.profile == nil)
    }

    @Test func aBuilderProfileStepBuildsCode() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        try write(Self.djangoBuilder, to: ".saturn/agents/django-builder.yaml", in: setup.project.filesRoot)
        try write("name: UI Reviewer\nkind: checker\n", to: ".saturn/agents/ui-reviewer.yaml", in: setup.project.filesRoot)

        #expect(setup.engine.buildsCode(WorkflowStep(id: "a", type: .agent, profile: "django-builder"), project: setup.project))
        #expect(!setup.engine.buildsCode(WorkflowStep(id: "b", type: .agent, profile: "ui-reviewer"), project: setup.project))
        #expect(!setup.engine.buildsCode(WorkflowStep(id: "c", type: .agent, profile: "ghost"), project: setup.project))
        #expect(setup.engine.buildsCode(WorkflowStep(id: "d", type: .agent, agent: .builder), project: setup.project))
    }

    @Test func explicitArgumentsOverrideTheProfile() throws {
        let profile = AgentProfile(id: "django-builder", name: "Django Builder", kind: .builder, model: "opus", instructions: "Use services.", skills: ["django-developer"])
        let filled = try #require(ResolvedAgent.resolve(profile: profile, kind: nil, model: nil, instructions: "Add login"))
        #expect(filled == ResolvedAgent(kind: .builder, model: "opus", instructions: "Use services.\n\nAdd login", skills: ["django-developer"], name: "Django Builder"))
        let overridden = try #require(ResolvedAgent.resolve(profile: profile, kind: .checker, model: "haiku", instructions: "Review", skills: ["qa-review"], name: "Second Opinion"))
        #expect(overridden == ResolvedAgent(kind: .checker, model: "haiku", instructions: "Use services.\n\nReview", skills: ["qa-review"], name: "Second Opinion"))
        #expect(ResolvedAgent.resolve(profile: nil, kind: nil, model: nil) == nil)
    }

    @Test func aStepContextRunsWithItsProfile() throws {
        let profile = AgentProfile(id: "ui-reviewer", name: "UI Reviewer", kind: .checker, model: "opus", instructions: "Check accessibility.")
        let config = ProjectConfig(agents: [profile])
        let now = Date()
        let context = StepContext(
            run: Run(projectId: 1, taskId: 1, workflow: "w", status: .running, startedAt: now),
            task: Chat(projectId: 1, title: "t", body: "", source: .chat, status: .incoming, createdAt: now, updatedAt: now),
            project: Project(name: "p", path: "/tmp/p", isOpen: true, createdAt: now, lastOpenedAt: now),
            step: WorkflowStep(id: "review", type: .agent, profile: "ui-reviewer", instructions: "Review the branch."),
            kind: nil, iteration: 1, attempt: 1, runStepID: 1, start: .fresh, inputs: StepInputs(taskTitle: "t", taskBody: "")
        )
        let resolved = context.resolvingProfile(in: config)
        #expect(resolved.kind == .checker)
        #expect(resolved.step.model == "opus")
        #expect(resolved.step.instructions == "Check accessibility.\n\nReview the branch.")
    }

    @Test func spawnArgumentsAcceptAProfileAlone() throws {
        let message = try HandoffTool.spawnAgent.decode(.object(["profile": .string("django-builder"), "task": .string("Add login")]))
        #expect(message == .spawnAgent(AgentSpawnRequest(profile: "django-builder", task: "Add login")))
        #expect(throws: HandoffError.missing("agent")) { try HandoffTool.spawnAgent.decode(.object(["task": .string("Add login")])) }
    }

    @Test func spawnAgentWithAProfileStartsItsKindModelAndInstructions() async throws {
        let (setup, lead) = try await LeadAgentControlTests().makeLead()
        defer { setup.harness.cleanUp() }
        try write(Self.djangoBuilder.replacingOccurrences(of: "skills: [django-developer]", with: ""), to: ".saturn/agents/django-builder.yaml", in: setup.project.filesRoot)
        try write("name: UI Reviewer\nkind: checker\nmodel: haiku\ndescription: Reviews the React UI.\ninstructions: Check accessibility.\n", to: ".saturn/agents/ui-reviewer.yaml", in: setup.project.filesRoot)

        let prompt = try setup.harness.runtime.turnSetup(for: lead.agent).systemPrompt
        #expect(prompt.contains("# Agent profiles"))
        #expect(prompt.contains("- `ui-reviewer` (checker): Reviews the React UI."))

        _ = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(profile: "django-builder", task: "CHAT add login")), from: lead.id)
        let builder = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.name == "Django Builder" })
        #expect(builder.kind == .builder && !builder.readOnly && builder.worktreePath != nil)
        #expect(builder.model == "opus")
        #expect(builder.task == "Follow the service layer pattern in api/services.\n\nCHAT add login")

        _ = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(profile: "ui-reviewer", task: "CHAT review", model: "sonnet")), from: lead.id)
        let reviewer = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.name == "UI Reviewer" })
        #expect(reviewer.kind == .checker && reviewer.readOnly)
        #expect(reviewer.model == "sonnet")

        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(profile: "ghost", task: "x")), from: lead.id)
        }
    }
}
