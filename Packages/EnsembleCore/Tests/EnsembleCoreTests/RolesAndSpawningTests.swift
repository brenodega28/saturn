import Foundation
import Testing
@testable import EnsembleCore

@Suite struct AgentNamingTests {
    @Test func singleAgentKeepsThePlainRoleName() {
        #expect(AgentNaming.names(base: "QA Engineer", count: 1, existing: []) == ["QA Engineer"])
    }

    @Test func severalAgentsAreNumberedFromOne() {
        #expect(AgentNaming.names(base: "Django Dev", count: 2, existing: ["Tech Lead"]) == ["Django Dev 1", "Django Dev 2"])
    }

    @Test func numberingContinuesPastExistingAgents() {
        #expect(AgentNaming.names(base: "Django Dev", count: 2, existing: ["Django Dev 1", "Django Dev 2"]) == ["Django Dev 3", "Django Dev 4"])
        #expect(AgentNaming.names(base: "Django Dev", count: 1, existing: ["Django Dev 4"]) == ["Django Dev 5"])
        #expect(AgentNaming.names(base: "QA", count: 1, existing: ["QA"]) == ["QA 2"])
    }

    @Test func namesThatCollideBySlugAreSkipped() {
        #expect(AgentNaming.names(base: "React Dev", count: 1, existing: ["react-dev"]) == ["React Dev 1"])
        #expect(AgentNaming.names(base: "Dev", count: 2, existing: ["dev 2"]) == ["Dev 3", "Dev 4"])
    }
}

@Suite struct RoleContextTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func assemblesPromptDocsAndSkillsWithWarnings() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "Run make test before committing.".write(to: repository.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repository.appending(path: "docs"), withIntermediateDirectories: true)
        try String(repeating: "a", count: 120).write(to: repository.appending(path: "docs/ARCHITECTURE.md"), atomically: true, encoding: .utf8)
        let skill = repository.appending(path: ".claude/skills/django-developer")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# Django".write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let role = RoleDefinition(id: "django-developer", name: "Django Developer", prompt: "Build Django features.", skills: ["django-developer", "drf-api-design"], docs: ["docs/ARCHITECTURE.md", "docs/MISSING.md"])
        let reviewer = RoleDefinition(id: "pr-reviewer", name: "PR Reviewer", editsCode: false)
        let config = ProjectConfig(roles: [role, reviewer], docs: DocsIndex(docs: [
            DocEntry(title: "AGENTS.md", path: "AGENTS.md", readers: .all),
            DocEntry(title: "Payments rules", prompt: "Never call the gateway outside a transaction.", readers: .coding),
            DocEntry(title: "Review checklist", prompt: "Check tests.", readers: .reviewers),
            DocEntry(title: "Old", prompt: "Ignore me.", readers: .all, enabled: false),
        ]))

        let context = RoleContext.build(role: role, config: config, repository: repository, documentLimit: 100)

        #expect(context.sections.map(\.title) == ["Role prompt", "AGENTS.md", "Payments rules", "ARCHITECTURE.md", "Skills"])
        #expect(context.sections.map(\.kind) == [.prompt, .fileDoc, .promptDoc, .fileDoc, .skills])
        #expect(context.sections[0].tokens == TokenEstimate.of("Build Django features."))
        #expect(TokenEstimate.of("12345678") == 2)
        #expect(context.totalTokens == context.sections.map(\.tokens).reduce(0, +))
        let architecture = context.sections[3]
        #expect(architecture.isTruncated)
        #expect(architecture.text.contains("[Truncated: this is the first 100 of 120 characters of docs/ARCHITECTURE.md"))
        #expect(Set(context.warnings) == [
            .missingDoc("docs/MISSING.md"),
            .missingSkill("drf-api-design"),
            .truncatedDoc(path: "docs/ARCHITECTURE.md", characters: 120, limit: 100),
        ])

        let prompt = context.systemPrompt
        #expect(prompt.hasPrefix("# Role: Django Developer\n\nBuild Django features."))
        #expect(prompt.contains("## AGENTS.md (AGENTS.md)\n\nRun make test before committing."))
        #expect(prompt.contains("## Payments rules\n\nNever call the gateway outside a transaction."))
        #expect(prompt.contains("- django-developer\n- drf-api-design"))
        #expect(!prompt.contains("Ignore me."))
        #expect(!prompt.contains("Check tests."))

        let reviewerContext = RoleContext.build(role: reviewer, config: config, repository: repository)
        #expect(reviewerContext.sections.map(\.title) == ["AGENTS.md", "Review checklist"])
        #expect(reviewerContext.warnings.isEmpty)
    }

    @Test func docsOutsideTheRepositoryAreTreatedAsMissing() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let role = RoleDefinition(id: "dev", name: "Dev", docs: ["../../etc/hosts"])
        let context = RoleContext.build(role: role, config: ProjectConfig(roles: [role]), repository: repository)
        #expect(context.sections.isEmpty)
        #expect(context.warnings == [.missingDoc("../../etc/hosts")])
    }

    @Test func installDefaultsCreatesTheConfigFolder() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        #expect(!ProjectConfigLoader.hasConfig(repository: repository))
        try ProjectConfigLoader.installDefaults(repository: repository)
        #expect(ProjectConfigLoader.hasConfig(repository: repository))
        #expect(!ProjectConfigLoader.load(repository: repository).roles.isEmpty)
    }

    @Test func skillsManifestListsSkillsPerRole() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let skill = repository.appending(path: ".claude/skills/react-developer")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# React".write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let config = ProjectConfig(roles: [
            RoleDefinition(id: "react-developer", name: "React Developer", skills: ["react-developer", "design-tokens"]),
            RoleDefinition(id: "qa", name: "QA"),
        ])

        let file = try SkillLibrary.writeManifest(for: config, repository: repository)
        let text = try String(contentsOf: file, encoding: .utf8)

        #expect(file.path.hasSuffix("docs/SKILLS.md"))
        #expect(text.contains("## QA\n\nNo skills."))
        #expect(text.contains("## React Developer\n\n- react-developer\n- design-tokens (missing from .claude/skills)"))
        #expect(SkillLibrary.missingSkills(for: config.roles[0], in: repository) == ["design-tokens"])
    }
}

@Suite struct ReadOnlyLaunchTests {
    @Test func readOnlyLaunchHasNoWritingToolsAndAddsDirectories() throws {
        let root = FileManager.default.temporaryDirectory
        let other = root.appending(path: "ensemble-sibling-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        let launch = ClaudeLaunch(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            worktree: root,
            session: .new("abc"),
            model: "sonnet",
            systemPrompt: "Review",
            environment: [:],
            readOnly: true,
            additionalDirectories: [other],
            extraArguments: ["--mcp-config", "/tmp/mcp.json"],
            extraAllowedTools: ["mcp__ensemble__submit_verdict"]
        )
        let arguments = launch.arguments
        let allowedIndex = try #require(arguments.firstIndex(of: "--allowedTools"))
        let allowed = Array(arguments[(allowedIndex + 1)...])

        #expect(!allowed.contains { $0.hasPrefix("Edit") || $0.hasPrefix("Write") || $0.hasPrefix("MultiEdit") || $0.hasPrefix("NotebookEdit") })
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Grep"))
        #expect(allowed.contains("Bash(git status:*)"))
        #expect(allowed.contains("Bash(pytest:*)"))
        for command in ["git add", "git commit", "git restore", "git stash", "git mv", "git rm", "git merge"] {
            #expect(!allowed.contains("Bash(\(command):*)"))
        }
        #expect(allowed.last == "mcp__ensemble__submit_verdict")

        let disallowedIndex = try #require(arguments.firstIndex(of: "--disallowedTools"))
        #expect(Array(arguments[(disallowedIndex + 1)...(disallowedIndex + 4)]) == ["Edit", "MultiEdit", "Write", "NotebookEdit"])
        let addDirIndex = try #require(arguments.firstIndex(of: "--add-dir"))
        #expect(arguments[addDirIndex + 1] == realPath(of: other))
        #expect(arguments.contains("--mcp-config"))
        #expect(arguments.firstIndex(of: "--mcp-config")! < allowedIndex)
    }

    @Test func codingLaunchKeepsWorktreeScopedWritesAndHasNoExtras() {
        let launch = ClaudeLaunch(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            worktree: FileManager.default.temporaryDirectory,
            session: .new("abc"),
            model: "sonnet",
            systemPrompt: "Build",
            environment: [:]
        )
        #expect(!launch.arguments.contains("--disallowedTools"))
        #expect(!launch.arguments.contains("--add-dir"))
        #expect(launch.arguments.contains("Bash(git commit:*)"))
        #expect(launch.arguments.contains("Bash(git merge:*)"))
        #expect(launch.arguments.contains { $0.hasPrefix("Write(//") })
    }
}

@MainActor
@Suite(.serialized) struct RoleSpawningTests {
    let django = RoleDefinition(id: "django-developer", name: "Django Dev", model: "haiku", editsCode: true)
    let reviewer = RoleDefinition(id: "pr-reviewer", name: "PR Reviewer", model: "opus", editsCode: false)

    func config() -> ProjectConfig { ProjectConfig(roles: [django, reviewer]) }

    @Test func spawnsNumberedAgentsFromARole() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let first = try await harness.runtime.spawn(in: harness.project, role: django, count: 2, config: config(), git: harness.repo.git)
        let second = try await harness.runtime.spawn(in: harness.project, role: django, count: 1, config: config(), git: harness.repo.git)

        let agents = (first + second).map(\.agent)
        #expect(agents.map(\.name) == ["Django Dev 1", "Django Dev 2", "Django Dev 3"])
        #expect(agents.allSatisfy { $0.role == "django-developer" && $0.model == "haiku" && !$0.readOnly && $0.status == .idle })
        #expect(agents.map(\.worktreePath).allSatisfy { $0?.contains("/.crew/django-dev-") == true })
        #expect(agents.map(\.branch) == ["crew/django-dev-1/task", "crew/django-dev-2/task", "crew/django-dev-3/task"])
        #expect(harness.launches().isEmpty)
        #expect(try harness.database.agents(inProject: harness.project.id!).count == 3)
    }

    @Test func chosenModelOverridesTheRoleModel() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let sessions = try await harness.runtime.spawn(
            in: harness.project, role: django, count: 2, config: config(), git: harness.repo.git, model: " claude-opus-5-5 "
        )
        #expect(sessions.map(\.agent.model) == ["claude-opus-5-5", "claude-opus-5-5"])
        #expect(try harness.database.agents(inProject: harness.project.id!).map(\.model) == ["claude-opus-5-5", "claude-opus-5-5"])

        let fallback = try await harness.runtime.spawn(in: harness.project, role: django, count: 1, config: config(), git: harness.repo.git, model: "  ")
        #expect(fallback.map(\.agent.model) == ["haiku"])
    }

    @Test func unknownModelIsRejectedBeforeAnythingIsCreated() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        await #expect(throws: AgentError.unknownModel("gpt-5")) {
            try await harness.runtime.spawn(in: harness.project, role: django, count: 1, config: config(), git: harness.repo.git, model: "gpt-5")
        }
        #expect(try harness.database.agents(inProject: harness.project.id!).isEmpty)
    }

    @Test func readOnlyRoleRunsFromTheProjectRootWithoutWritingTools() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let sessions = try await harness.runtime.spawn(in: harness.project, role: reviewer, count: 1, config: config(), git: harness.repo.git, task: "Review the README")
        let session = try #require(sessions.first)
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 1 }

        let agent = session.agent
        #expect(agent.name == "PR Reviewer")
        #expect(agent.readOnly)
        #expect(agent.worktreePath == nil)
        #expect(agent.branch == nil)
        #expect(agent.model == "opus")
        #expect(try harness.database.agent(id: session.id)?.readOnly == true)
        #expect(session.transcript.session.map { realPath(of: URL(fileURLWithPath: $0.cwd)) } == realPath(of: harness.repo.root))

        let launch = try #require(harness.launches().first)
        #expect(launch.contains("--disallowedTools Edit MultiEdit Write NotebookEdit"))
        #expect(!launch.contains("Write(/"))
        #expect(!launch.contains("Bash(git commit:*)"))
        #expect(!launch.contains("Bash(git merge:*)"))
        #expect(launch.contains("Bash(git diff:*)"))
        #expect(launch.contains("a read-only agent run by Ensemble"))
        #expect(try await harness.repo.branches() == ["main"])
    }

    @Test func roleContextIsAppendedToTheSystemPrompt() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        var role = django
        role.prompt = "Follow Django conventions."
        try ProjectConfigLoader.write(role, repository: harness.repo.root)
        try ProjectConfigLoader.write(DocsIndex(docs: [DocEntry(title: "Rules", prompt: "Keep views thin.")]), repository: harness.repo.root)

        let sessions = try await harness.runtime.spawn(in: harness.project, role: role, count: 1, config: ProjectConfigLoader.load(repository: harness.repo.root), git: harness.repo.git, task: "Add a view")
        let session = try #require(sessions.first)
        try await waitUntil { session.agent.status == .idle }

        let log = harness.launches().joined(separator: "\n")
        #expect(log.contains("# Role: Django Dev"))
        #expect(log.contains("Follow Django conventions."))
        #expect(log.contains("## Rules"))
        #expect(log.contains("Keep views thin."))
    }

    @Test func turnsBeyondTheProjectCapWaitForAFreeSlot() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        try harness.database.updateSettings(ProjectSettings(maxConcurrentAgents: 1), forProject: projectId)
        #expect(harness.runtime.maxConcurrentAgents(inProject: projectId) == 1)

        let sessions = try await harness.runtime.spawn(in: harness.project, role: django, count: 2, config: config(), git: harness.repo.git, task: "Add a world line to the README")
        let first = sessions[0]
        let second = sessions[1]
        try await waitUntil { first.transcript.activeTool?.name == "Bash" }

        #expect(first.agent.status == .working)
        #expect(second.agent.status == .waiting)
        #expect(second.isQueued)
        #expect(!second.isRunning)
        #expect(harness.runtime.queuedSessions(inProject: projectId).map(\.id) == [second.id])
        #expect(try harness.database.agent(id: second.id)?.status == .waiting)
        #expect(harness.launches().count == 1)

        first.pause()
        try await waitUntil { first.agent.status == .paused && second.transcript.activeTool?.name == "Bash" }
        #expect(second.agent.status == .working)
        #expect(!second.isQueued)
        #expect(harness.launches().count == 2)
        #expect(harness.runtime.queuedSessions(inProject: projectId).isEmpty)

        first.resume()
        #expect(first.agent.status == .waiting)
        #expect(first.isQueued)
        first.pause()
        #expect(first.agent.status == .paused)
        #expect(!first.isQueued)
        #expect(harness.runtime.queuedSessions(inProject: projectId).isEmpty)

        second.stop()
        try await waitUntil { second.agent.status == .stopped }
        #expect(harness.launches().count == 2)
    }

    @Test func raisingTheCapStartsQueuedTurns() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        try harness.database.updateSettings(ProjectSettings(maxConcurrentAgents: 1), forProject: projectId)

        let sessions = try await harness.runtime.spawn(in: harness.project, role: django, count: 3, config: config(), git: harness.repo.git, task: "Add a world line to the README")
        try await waitUntil { sessions[0].transcript.activeTool?.name == "Bash" }
        #expect(sessions.dropFirst().allSatisfy { $0.isQueued })

        try harness.database.updateSettings(ProjectSettings(maxConcurrentAgents: 3), forProject: projectId)
        harness.runtime.startQueuedTurns(inProject: projectId)
        try await waitUntil { sessions.allSatisfy { $0.transcript.activeTool?.name == "Bash" } }
        #expect(harness.runtime.runningCount(inProject: projectId) == 3)

        for session in sessions { session.stop() }
        try await waitUntil { sessions.allSatisfy { $0.agent.status == .stopped } }
    }

    @Test func pinIsPersisted() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let sessions = try await harness.runtime.spawn(in: harness.project, role: reviewer, count: 1, config: config(), git: harness.repo.git, pinned: true)
        let session = try #require(sessions.first)
        #expect(try harness.database.agent(id: session.id)?.isPinned == true)

        session.togglePin()
        #expect(!session.agent.isPinned)
        #expect(try harness.database.agent(id: session.id)?.isPinned == false)

        session.setPinned(true)
        let reloaded = AgentHarness.makeRuntime(database: harness.database, data: harness.data, bin: harness.bin)
        let restored = try reloaded.sessions(inProject: harness.project.id!)
        #expect(restored.first?.agent.isPinned == true)
    }

    @Test func queuedAgentsAreInterruptedAfterRelaunch() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let sessions = try await harness.runtime.spawn(in: harness.project, role: reviewer, count: 1, config: config(), git: harness.repo.git)
        var agent = try #require(sessions.first?.agent)
        agent.status = .waiting
        try harness.database.save(agent)

        let reloaded = AgentHarness.makeRuntime(database: harness.database, data: harness.data, bin: harness.bin)
        try reloaded.recoverAfterLaunch()
        #expect(try harness.database.agent(id: agent.id!)?.status == .interrupted)
    }
}
