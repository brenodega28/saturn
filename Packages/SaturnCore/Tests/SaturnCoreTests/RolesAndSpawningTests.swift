import Foundation
import Testing
import Yams
@testable import SaturnCore

@Suite struct RoleVerbTests {
    @Test func decodesVerbFromRoleFile() throws {
        let role = try YAMLDecoder().decode(RoleDefinition.self, from: "name: Tester\nverb: testing\n")
        #expect(role.verb == "testing")
        #expect(role.activeVerb == "testing")
    }

    @Test func missingVerbFallsBackToWorking() throws {
        let role = try YAMLDecoder().decode(RoleDefinition.self, from: "name: Coder\n")
        #expect(role.verb == nil)
        #expect(role.activeVerb == "working")
    }

    @Test func builtInRolesHaveDefaultVerbs() {
        #expect(AgentKind.lead.builtInRole.activeVerb == "planning")
        #expect(AgentKind.builder.builtInRole.activeVerb == "building")
        #expect(AgentKind.checker.builtInRole.activeVerb == "checking")
    }
}

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

    @Test func leadDisplayNameDropsTheNumber() {
        #expect(AgentNaming.displayName(of: "Lead 17", kind: .lead) == "Lead")
        #expect(AgentNaming.displayName(of: "Lead", kind: .lead) == "Lead")
    }

    @Test func nonLeadDisplayNameKeepsTheNumber() {
        #expect(AgentNaming.displayName(of: "Builder 2", kind: .builder) == "Builder 2")
        #expect(AgentNaming.displayName(of: "Checker 2", kind: .checker) == "Checker 2")
        #expect(AgentNaming.displayName(of: "Builder 2", kind: nil) == "Builder 2")
    }

    @Test func leadDisplayNameKeepsNamesOutsideThePattern() {
        #expect(AgentNaming.displayName(of: "Ada", kind: .lead) == "Ada")
        #expect(AgentNaming.displayName(of: "Lead Backup", kind: .lead) == "Lead Backup")
    }
}

@Suite struct AgentKindTests {
    @Test func builtInKindsHaveFixedCapabilitiesAndModels() {
        #expect(AgentKind.allCases.map(\.builtInRole.id) == ["lead", "builder", "checker"])
        #expect(AgentKind.allCases.map(\.builtInRole.name) == ["Lead", "Builder", "Checker"])
        let lead = AgentKind.lead.builtInRole
        #expect(!lead.editsCode && lead.canSpawn && lead.model == "opus")
        #expect(lead.prompt.contains("plan one task by default"))
        #expect(lead.prompt.contains("Two tasks interfere"))
        #expect(lead.prompt.contains("ask questions instead of guessing"))
        #expect(lead.prompt.contains("propose a run"))
        #expect(lead.prompt.contains("skills"))
        let builder = AgentKind.builder.builtInRole
        #expect(builder.editsCode && !builder.canSpawn && builder.model == "sonnet")
        let checker = AgentKind.checker.builtInRole
        #expect(!checker.editsCode && !checker.canSpawn && checker.model == "sonnet")
        #expect(checker.prompt.contains("read-only"))
        #expect(checker.prompt.contains("start fresh"))
        #expect(checker.prompt.contains("against the plan"))
    }

    @Test func legacyRoleIDsAreGuessedByName() {
        #expect(AgentKind.guessing(roleID: "pr-reviewer") == .checker)
        #expect(AgentKind.guessing(roleID: "qa-engineer") == .checker)
        #expect(AgentKind.guessing(roleID: "e2e-tester") == .checker)
        #expect(AgentKind.guessing(roleID: "tech-lead") == .lead)
        #expect(AgentKind.guessing(roleID: "project-manager") == .lead)
        #expect(AgentKind.guessing(roleID: "claude-code") == .builder)
        #expect(AgentKind.guessing(roleID: "django-developer") == .builder)
        #expect(AgentKind.guessing(roleID: "checker") == .checker)
    }
}

@Suite struct RoleContextTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "saturn-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func assemblesPromptDocsAndChosenSkillsWithWarnings() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "Run make test before committing.".write(to: repository.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repository.appending(path: "docs"), withIntermediateDirectories: true)
        try String(repeating: "a", count: 120).write(to: repository.appending(path: "docs/ARCHITECTURE.md"), atomically: true, encoding: .utf8)
        let skill = repository.appending(path: ".claude/skills/django-developer")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# Django".write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let config = ProjectConfig(docs: DocsIndex(docs: [
            DocEntry(title: "AGENTS.md", path: "AGENTS.md", readers: .all),
            DocEntry(title: "Payments rules", prompt: "Never call the gateway outside a transaction.", readers: .coding),
            DocEntry(title: "Architecture", path: "docs/ARCHITECTURE.md", readers: .coding),
            DocEntry(title: "Missing", path: "docs/MISSING.md", readers: .coding),
            DocEntry(title: "Review checklist", prompt: "Check tests.", readers: .reviewers),
            DocEntry(title: "Old", prompt: "Ignore me.", readers: .all, enabled: false),
        ]))

        let context = RoleContext.build(kind: .builder, skills: ["django-developer", "drf-api-design"], config: config, repository: repository, documentLimit: 100)

        #expect(context.sections.map(\.title) == ["Role prompt", "AGENTS.md", "Payments rules", "Architecture", "Skills"])
        #expect(context.sections.map(\.kind) == [.prompt, .fileDoc, .promptDoc, .fileDoc, .skills])
        #expect(context.sections[0].tokens == TokenEstimate.of(AgentKind.builderPrompt))
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
        #expect(prompt.hasPrefix("# Role: Builder\n\nYou are a careful software engineer."))
        #expect(prompt.contains("## AGENTS.md (AGENTS.md)\n\nRun make test before committing."))
        #expect(prompt.contains("## Payments rules\n\nNever call the gateway outside a transaction."))
        #expect(prompt.contains("- django-developer\n- drf-api-design"))
        #expect(!prompt.contains("Ignore me."))
        #expect(!prompt.contains("Check tests."))

        let checkerContext = RoleContext.build(kind: .checker, config: config, repository: repository)
        #expect(checkerContext.sections.map(\.title) == ["Role prompt", "AGENTS.md", "Review checklist"])
        #expect(checkerContext.warnings.isEmpty)
        #expect(!checkerContext.systemPrompt.contains("# Skills"))
    }

    @Test func docsOutsideTheRepositoryAreTreatedAsMissing() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let config = ProjectConfig(docs: DocsIndex(docs: [DocEntry(title: "Hosts", path: "../../etc/hosts")]))
        let context = RoleContext.build(kind: .builder, config: config, repository: repository)
        #expect(context.sections.map(\.kind) == [.prompt])
        #expect(context.warnings == [.missingDoc("../../etc/hosts")])
    }

    @Test func installDefaultsCreatesTheConfigFolder() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        #expect(!ProjectConfigLoader.hasConfig(repository: repository))
        try ProjectConfigLoader.installDefaults(repository: repository)
        #expect(ProjectConfigLoader.hasConfig(repository: repository))
        #expect(ProjectConfigLoader.load(repository: repository).roles.map(\.id) == ["lead", "builder", "checker"])
    }

    @Test func installedSkillsComeFromTheProjectPluginsAndTheGlobalFolder() throws {
        let repository = try makeRepository()
        let home = try makeRepository()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: home)
        }
        for (root, name, description) in [(repository, "react-developer", "Build React"), (home, "qa-review", "Review like QA"), (home, "react-developer", "Global copy")] {
            let folder = SkillLibrary.directory(in: root).appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \"\(description)\"\n---\n\nBody".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: SkillLibrary.directory(in: repository).appending(path: "not-a-skill"), withIntermediateDirectories: true)

        #expect(SkillLibrary.installedSkills(in: repository, home: home) == ["react-developer", "qa-review"])
        let skills = SkillLibrary.skills(in: repository, pluginSkills: ["sentry:django"], home: home)
        #expect(skills == [
            InstalledSkill(name: "react-developer", source: .project, description: "Build React"),
            InstalledSkill(name: "sentry:django", source: .plugin),
            InstalledSkill(name: "qa-review", source: .global, description: "Review like QA"),
        ])
        #expect(SkillLibrary.unknownSkills(["qa-review", "sentry:django", "nope"], in: repository, pluginSkills: ["sentry:django"], home: home) == ["nope"])
    }
}

@Suite struct ReadOnlyLaunchTests {
    @Test func readOnlyLaunchWritesOnlyInsideTempFoldersAndAddsDirectories() throws {
        let root = FileManager.default.temporaryDirectory
        let other = root.appending(path: "saturn-sibling-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            extraAllowedTools: ["mcp__saturn__submit_verdict"]
        )
        let arguments = launch.arguments
        let allowedIndex = try #require(arguments.firstIndex(of: "--allowedTools"))
        let allowed = Array(arguments[(allowedIndex + 1)...])

        let writing = allowed.filter { tool in AgentPermissions.fileWritingTools.contains { tool.hasPrefix($0) } }
        #expect(Set(writing) == Set(["//tmp/**", "//private/tmp/**", "//var/folders/**", "//private/var/folders/**"].flatMap { root in
            AgentPermissions.fileWritingTools.map { "\($0)(\(root))" }
        }))
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Grep"))
        #expect(allowed.contains("Bash(git status:*)"))
        #expect(allowed.contains("Bash(pytest:*)"))
        for command in ["git add", "git commit", "git restore", "git stash", "git mv", "git rm", "git merge"] {
            #expect(!allowed.contains("Bash(\(command):*)"))
        }
        #expect(allowed.last == "mcp__saturn__submit_verdict")

        #expect(!arguments.contains("--disallowedTools"))
        #expect(arguments[try #require(arguments.firstIndex(of: "--tools")) + 1] == "Bash,Skill,Read,Glob,Grep,Edit,MultiEdit,Write,NotebookEdit")
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
    @Test func spawnsNumberedBuilders() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let first = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 2, git: harness.repo.git, name: "Django Dev", model: "haiku")
        let second = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, name: "Django Dev", model: "haiku")

        let agents = (first + second).map(\.agent)
        #expect(agents.map(\.name) == ["Django Dev 1", "Django Dev 2", "Django Dev 3"])
        #expect(agents.allSatisfy { $0.role == "builder" && $0.model == "haiku" && !$0.readOnly && $0.status == .idle })
        #expect(agents.map(\.worktreePath).allSatisfy { $0?.contains("/.crew/django-dev-") == true })
        #expect(agents.map(\.branch) == ["crew/django-dev-1/task", "crew/django-dev-2/task", "crew/django-dev-3/task"])
        #expect(harness.launches().isEmpty)
        #expect(try harness.database.agents(inProject: harness.project.id!).count == 3)
    }

    @Test func chosenModelOverridesTheKindDefault() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let sessions = try await harness.runtime.spawn(
            in: harness.project, kind: .builder, count: 2, git: harness.repo.git, model: " claude-opus-5-5 "
        )
        #expect(sessions.map(\.agent.model) == ["claude-opus-5-5", "claude-opus-5-5"])
        #expect(try harness.database.agents(inProject: harness.project.id!).map(\.model) == ["claude-opus-5-5", "claude-opus-5-5"])

        let fallback = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, model: "  ")
        #expect(fallback.map(\.agent.model) == ["sonnet"])
    }

    @Test func unknownModelIsRejectedBeforeAnythingIsCreated() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        await #expect(throws: AgentError.unknownModel("gpt-5")) {
            try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, model: "gpt-5")
        }
        #expect(try harness.database.agents(inProject: harness.project.id!).isEmpty)
    }

    @Test func spawnKeepsValidSkillsAndRejectsUnknownOnes() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let folder = SkillLibrary.directory(in: harness.repo.root).appending(path: "design-tokens")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Tokens".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        harness.runtime.pluginSkills = { _ in ["sentry:django"] }

        let session = try #require(try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, skills: ["design-tokens", "sentry:django"]).first)
        #expect(session.agent.skills == ["design-tokens", "sentry:django"])
        #expect(try harness.database.agent(id: session.id)?.skills == ["design-tokens", "sentry:django"])
        let prompt = try harness.runtime.turnSetup(for: session.agent).systemPrompt
        #expect(prompt.contains("- design-tokens\n- sentry:django"))

        await #expect(throws: AgentError.unknownSkills(["made-up-skill-q"])) {
            try await harness.runtime.spawn(in: harness.project, kind: .checker, count: 1, git: harness.repo.git, skills: ["design-tokens", "made-up-skill-q"])
        }
        #expect(AgentError.unknownSkills(["made-up-skill-q"]).localizedDescription.contains("“made-up-skill-q” isn’t an installed skill"))
        #expect(try harness.database.agents(inProject: harness.project.id!).count == 1)
    }

    @Test func readOnlyCheckerRunsFromTheProjectRootWritingOnlyInsideTempFolders() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let sessions = try await harness.runtime.spawn(in: harness.project, kind: .checker, count: 1, git: harness.repo.git, model: "opus", task: "Review the README")
        let session = try #require(sessions.first)
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 1 }

        let agent = session.agent
        #expect(agent.name == "Checker")
        #expect(agent.kind == .checker)
        #expect(agent.readOnly)
        #expect(agent.worktreePath == nil)
        #expect(agent.branch == nil)
        #expect(agent.model == "opus")
        #expect(try harness.database.agent(id: session.id)?.readOnly == true)
        #expect(session.transcript.session.map { realPath(of: URL(fileURLWithPath: $0.cwd)) } == realPath(of: harness.repo.root))

        let launch = try #require(harness.launches().first)
        #expect(!launch.contains("--disallowedTools"))
        #expect(launch.contains("Write(//private/tmp/**)"))
        #expect(!launch.contains("Write(/" + realPath(of: harness.repo.root)))
        #expect(!launch.contains("Bash(git commit:*)"))
        #expect(!launch.contains("Bash(git merge:*)"))
        #expect(launch.contains("Bash(git diff:*)"))
        #expect(launch.contains("a read-only agent run by Saturn"))
        #expect(try await harness.repo.branches() == ["main"])
    }

    @Test func extraCommandsFollowTheKindsProfile() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        var permissions = PermissionsConfig()
        let developer = try #require(permissions.profiles.firstIndex { $0.id == "developer" })
        permissions.profiles[developer].extraCommands = ["xcodegen", "open", "screencapture", "pkill", "killall"]
        try ProjectConfigLoader.write(permissions, repository: harness.repo.root)

        for kind in [AgentKind.builder, .checker] {
            let session = try #require(try await harness.runtime.spawn(in: harness.project, kind: kind, count: 1, git: harness.repo.git).first)
            let setup = try harness.runtime.turnSetup(for: session.agent)
            let opted = kind == .builder
            #expect(setup.permissions?.profile.id == kind.permissionProfileID)
            for command in ["xcodegen", "open", "screencapture", "pkill", "killall"] {
                #expect(setup.permissions?.commands.contains(command) == opted, "\(kind) \(command)")
                #expect(setup.systemPrompt.contains("`\(command)`") == opted, "\(kind) \(command)")
            }
        }
    }

    @Test func readOnlyCheckersAndLeadsAreDeniedEditsByTheHook() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let checker = try #require(try await harness.runtime.spawn(in: harness.project, kind: .checker, count: 1, git: harness.repo.git).first)
        let lead = try #require(try await harness.runtime.spawn(in: harness.project, kind: .lead, count: 1, git: harness.repo.git).first)
        let builder = try #require(try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git).first)

        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
            let input: JSONValue = .object([
                "hook_event_name": .string("PreToolUse"), "tool_name": .string(tool),
                "tool_input": .object(["file_path": .string("tests/test_refunds.py"), "notebook_path": .string("n.ipynb")]),
            ])
            let scratch: JSONValue = .object([
                "hook_event_name": .string("PreToolUse"), "tool_name": .string(tool),
                "tool_input": .object(["file_path": .string("/private/tmp/claude-501/x/scratchpad/x.py"), "notebook_path": .string("/tmp/q7/n.ipynb")]),
            ])
            for session in [checker, lead] {
                let reply = await harness.runtime.handleHook(input, agentID: session.id)
                #expect(reply["hookSpecificOutput"]?["permissionDecision"]?.string == "deny", "\(session.agent.name) \(tool)")
                let scratchReply = await harness.runtime.handleHook(scratch, agentID: session.id)
                #expect(scratchReply["hookSpecificOutput"]?["permissionDecision"]?.string == "allow", "\(session.agent.name) \(tool)")
            }
            #expect(await harness.runtime.handleHook(input, agentID: builder.id) == .object([:]), "\(tool)")
        }

        let url = URL(string: "http://localhost/hook")!
        for session in [checker, lead] {
            let policy = try #require(try harness.runtime.turnSetup(for: session.agent).permissions)
            #expect(policy.level(.editFiles) == .never)
            let hooks = try #require(AgentRuntime.hookSettings(checks: nil, policy: policy, url: url))
            guard case .array(let entries) = hooks["PreToolUse"] else { Issue.record("no PreToolUse hook"); continue }
            let matcher = entries.first?["matcher"]?.string ?? ""
            #expect(AgentPermissions.fileWritingTools.allSatisfy(matcher.split(separator: "|").map(String.init).contains))
        }
    }

    @Test func requestAgentsMayReadClaudeArtifactsAndTheWebButNoAgentMayWriteArtifacts() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        let task = try harness.database.insert(Chat(projectId: projectId, title: "Refunds", body: "", source: .chat, status: .running, createdAt: .now, updatedAt: .now))
        let run = try harness.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "small-task", status: .running, startedAt: .now, title: "Refunds"), state: RunEngineState())
        let runID = try #require(run.id)

        let lead = try harness.runtime.createLeadAgent(in: harness.project, taskId: try #require(task.id))
        let builders = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 2, git: harness.repo.git)
        let reviewers = try await harness.runtime.spawn(in: harness.project, kind: .checker, count: 2, git: harness.repo.git)
        builders[0].attach(toRun: runID)
        reviewers[0].attach(toRun: runID)
        let bound = [lead, builders[0], reviewers[0]]
        let unbound = [builders[1], reviewers[1]]

        for session in bound + unbound {
            let setup = try harness.runtime.turnSetup(for: session.agent)
            let arguments = ClaudeLaunch(
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
            let index = try #require(arguments.lastIndex(of: "--allowedTools"))
            let allowed = Set(arguments[(index + 1)...])
            let isBound = bound.contains { $0 === session }

            #expect(!allowed.contains("Artifact"), "\(session.agent.name)")
            #expect(allowed.isSuperset(of: AgentPermissions.artifactTools) == isBound, "\(session.agent.name)")
            #expect(allowed.isDisjoint(with: AgentPermissions.artifactTools) == !isBound, "\(session.agent.name)")
            let mayBrowse = isBound && session.agent.readOnly
            #expect(allowed.isSuperset(of: AgentPermissions.webTools) == mayBrowse, "\(session.agent.name)")
            #expect(allowed.isDisjoint(with: AgentPermissions.webTools) == !mayBrowse, "\(session.agent.name)")
            #expect(setup.systemPrompt.contains("`ArtifactData`, `ArtifactComments` and `ArtifactCheck`") == isBound, "\(session.agent.name)")
        }
    }

    @Test func kindContextIsAppendedToTheSystemPrompt() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try ProjectConfigLoader.write(DocsIndex(docs: [DocEntry(title: "Rules", prompt: "Keep views thin.")]), repository: harness.repo.root)

        let sessions = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 1, git: harness.repo.git, name: "Django Dev", task: "Add a view")
        let session = try #require(sessions.first)
        try await waitUntil { session.agent.status == .idle }

        let log = harness.launches().joined(separator: "\n")
        #expect(log.contains("# Role: Builder"))
        #expect(log.contains("You are a careful software engineer."))
        #expect(log.contains("## Rules"))
        #expect(log.contains("Keep views thin."))
    }

    @Test func turnsBeyondTheProjectCapWaitForAFreeSlot() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        try harness.database.updateSettings(ProjectSettings(maxConcurrentAgents: 1), forProject: projectId)
        #expect(harness.runtime.maxConcurrentAgents(inProject: projectId) == 1)

        let sessions = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 2, git: harness.repo.git, task: "Add a world line to the README")
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

        let sessions = try await harness.runtime.spawn(in: harness.project, kind: .builder, count: 3, git: harness.repo.git, task: "Add a world line to the README")
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

        let sessions = try await harness.runtime.spawn(in: harness.project, kind: .checker, count: 1, git: harness.repo.git, pinned: true)
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
        let sessions = try await harness.runtime.spawn(in: harness.project, kind: .checker, count: 1, git: harness.repo.git)
        var agent = try #require(sessions.first?.agent)
        agent.status = .waiting
        try harness.database.save(agent)

        let reloaded = AgentHarness.makeRuntime(database: harness.database, data: harness.data, bin: harness.bin)
        try reloaded.recoverAfterLaunch()
        #expect(try harness.database.agent(id: agent.id!)?.status == .interrupted)
    }
}
