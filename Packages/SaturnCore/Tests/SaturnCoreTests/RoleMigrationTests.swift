import Foundation
import Testing
import Yams
@testable import SaturnCore

@Suite struct RoleMigrationTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "saturn-migrate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: ".saturn/roles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".saturn/workflows"), withIntermediateDirectories: true)
        return root
    }

    func write(_ text: String, _ path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in root: URL) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    static let techLead = """
    name: Tech Lead
    description: Plans by area and reviews code
    model: opus
    edits_code: false
    can_spawn: true
    prompt: |
      You are the Tech Lead. When planning, read the request and the codebase, then plan one task by default:
      one agent working alone is usually faster and easier to test than several. Split into more tasks only when
      every task works and can be tested on its own. Two tasks interfere when one needs the other's output to work,
      or when either can't be tested without the other; if any tasks would interfere, keep them in one task. When
      you do split, say in the summary why the tasks can't interfere. Assign each task to the role best suited to
      it and say which files or folders it owns.
      When reviewing, read every branch against the plan and the request. Approve only work you would merge.
      When you request changes, name the agent and file and describe the expected fix.
    """

    static let claudeCode = """
    name: Claude Code
    model: opus
    edits_code: true
    can_spawn: false
    permission_profile: app_testing
    budget_per_run: 4
    prompt: 'You are a careful software engineer. Build exactly the task you were given, follow the conventions you see

      in the codebase, add or update tests, run them, and commit your work to your branch.

      '
    """

    static let payments = """
    name: Payments Specialist
    description: Knows the Stripe integration
    model: claude-sonnet-5-5
    edits_code: true
    can_spawn: false
    skills: [stripe-webhooks]
    docs: [docs/PAYMENTS.md]
    prompt: |
      You own the payments code. Amounts are always integer cents; never use floats for money.
      Every webhook handler must be idempotent and keyed by the Stripe event id.
    """

    static let workflow = """
    name: Feature delivery
    version: 1
    budget: 20
    steps:
      - id: plan
        type: agent
        role: tech-lead
        next: build
      - id: build
        type: spawn
        role: claude-code
        next: pay
      - id: pay
        type: agent
        role: payments
        budget: 1
        next: review
      - id: review
        type: agent
        role: pr-reviewer
        routes:
          approved: qa
          changes_requested: build
      - id: qa
        type: agent
        role: qa-engineer
        routes:
          passed: end
          failed: build
    end:
      action: pull_request
    """

    func fixture() throws -> URL {
        let root = try makeRepository()
        try write(Self.techLead, ".saturn/roles/tech-lead.yaml", in: root)
        try write(Self.claudeCode, ".saturn/roles/claude-code.yaml", in: root)
        try write(Self.payments, ".saturn/roles/payments.yaml", in: root)
        try write(Self.workflow, ".saturn/workflows/feature-delivery.yaml", in: root)
        try write("docs:\n  - path: docs/PAYMENTS.md\n    readers: [payments, tech-lead]\n  - path: docs/QA.md\n    readers: [qa-engineer]\n", ".saturn/docs.yaml", in: root)
        return root
    }

    @Test func migratesStepsSkillsDocsPermissionsAndMovesRolesAside() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let notices = try RoleMigration.migrate(repository: root)

        let workflow = try YAMLDecoder().decode(WorkflowDefinition.self, from: try read(".saturn/workflows/feature-delivery.yaml", in: root))
        #expect(workflow.steps.map(\.agent) == [.lead, .builder, .builder, .checker, .checker])
        #expect(workflow.steps.map(\.model) == ["opus", "opus", "claude-sonnet-5-5", nil, nil])
        #expect(!(try read(".saturn/workflows/feature-delivery.yaml", in: root)).contains("budget"))
        #expect(workflow.steps.allSatisfy { $0.legacyRole == nil })
        let yaml = try read(".saturn/workflows/feature-delivery.yaml", in: root)
        #expect(!yaml.contains("role:"))

        let skill = try read(".claude/skills/payments/SKILL.md", in: root)
        #expect(skill.hasPrefix("---\nname: payments\ndescription: \"Knows the Stripe integration\"\n---\n\n# Payments Specialist\n\n"))
        #expect(skill.contains("Amounts are always integer cents"))
        #expect(skill.contains("## Related skills\n\n- stripe-webhooks"))
        #expect(skill.contains("## Docs\n\n- docs/PAYMENTS.md"))
        #expect(SkillLibrary.describe(skillFile: root.appending(path: ".claude/skills/payments/SKILL.md")) == "Knows the Stripe integration")
        #expect(!exists(".claude/skills/tech-lead", in: root))
        #expect(!exists(".claude/skills/claude-code", in: root))

        #expect(!exists(".saturn/roles", in: root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".saturn/legacy-roles").path).sorted() == ["claude-code.yaml", "payments.yaml", "tech-lead.yaml"])
        #expect(try read(".saturn/legacy-roles/payments.yaml", in: root) == Self.payments)

        let docs = try YAMLDecoder().decode(DocsIndex.self, from: try read(".saturn/docs.yaml", in: root))
        #expect(docs.docs.map(\.readers) == [.roles(["lead", "builder"]), .reviewers])

        let permissions = try YAMLDecoder().decode(PermissionsConfig.self, from: try read(".saturn/permissions.yaml", in: root))
        #expect(permissions.profile("developer")?.extraCommands == ["xcodegen", "open", "screencapture", "pkill", "killall"])
        #expect(permissions.profile("reviewer")?.extraCommands == [])

        let messages = notices.map { "\($0.file): \($0.message)" }
        #expect(messages.contains(".saturn/workflows/feature-delivery.yaml: steps.review: role “pr-reviewer” has no file, so it became a Checker by its name"))
        #expect(messages.contains(".saturn/workflows/feature-delivery.yaml: steps.qa: role “qa-engineer” has no file, so it became a Checker by its name"))
        #expect(messages.contains(".saturn/workflows/feature-delivery.yaml: steps.plan: role “tech-lead” is now agent lead on opus"))
        #expect(messages.contains { $0.hasPrefix(".claude/skills/payments/SKILL.md: made from role “payments”") })
        #expect(messages.contains { $0.hasPrefix(".saturn/roles: moved to .saturn/legacy-roles") })
    }

    @Test func aSecondRunChangesNothing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try RoleMigration.migrate(repository: root)
        let paths = [".saturn/workflows/feature-delivery.yaml", ".claude/skills/payments/SKILL.md", ".saturn/docs.yaml", ".saturn/permissions.yaml", ".saturn/legacy-roles/tech-lead.yaml"]
        let before = try paths.map { try read($0, in: root) }

        #expect(!RoleMigration.needsMigration(repository: root))
        #expect(try RoleMigration.migrate(repository: root).isEmpty)
        #expect(try paths.map { try read($0, in: root) } == before)
        #expect(ProjectConfigLoader.load(repository: root).migrationNotices.isEmpty)
    }

    @Test func noticesFromAnEarlierLoadWaitForTheCallerThatPostsThem() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let early = ProjectConfigLoader.load(repository: root)
        #expect(!early.migrationNotices.isEmpty)
        let later = ProjectConfigLoader.load(repository: root)
        #expect(later.migrationNotices.isEmpty)

        let posted = RoleMigration.takeNotices(for: root)
        #expect(posted == early.migrationNotices)
        #expect(posted.contains { $0.file == ".claude/skills/payments/SKILL.md" })
        #expect(RoleMigration.takeNotices(for: root).isEmpty)
        let symlinked = URL(fileURLWithPath: realPath(of: root))
        _ = ProjectConfigLoader.load(repository: symlinked)
        #expect(RoleMigration.takeNotices(for: root).isEmpty)
    }

    @Test func existingSkillFilesAreNeverOverwritten() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("my own payments skill", ".claude/skills/payments/SKILL.md", in: root)

        let notices = try RoleMigration.migrate(repository: root)

        #expect(try read(".claude/skills/payments/SKILL.md", in: root) == "my own payments skill")
        #expect(notices.contains { $0.file == ".claude/skills/payments/SKILL.md" && $0.message.hasPrefix("already exists") })
        #expect(exists(".saturn/legacy-roles/payments.yaml", in: root))
    }

    @Test func bundledPromptsNeedNoSkillButCustomizedOnesDo() {
        #expect(RoleMigration.isBundledPrompt(Self.claudeCodePrompt))
        #expect(RoleMigration.isBundledPrompt("You are the QA engineer. You work in a temporary worktree where every branch of this run has been merged. Run the project's test suites and exercise the changed behavior."))
        #expect(RoleMigration.isBundledPrompt(""))
        #expect(!RoleMigration.isBundledPrompt("You are the QA engineer. Run the project’s test suites and run the app to make sure it’s working."))
        #expect(RoleMigration.needsSkill(RoleDefinition(id: "x", name: "X", prompt: Self.claudeCodePrompt, docs: ["AGENTS.md"])))
        #expect(!RoleMigration.needsSkill(RoleDefinition(id: "x", name: "X", prompt: Self.claudeCodePrompt)))
    }

    static let claudeCodePrompt = "You are a careful software engineer. Build exactly the task you were given, follow the conventions you see\nin the codebase, add or update tests, run them, and commit your work to your branch.\n"

    @Test func workflowsWithoutARolesFolderStillMigrateByName() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appending(path: ".saturn/roles"))
        try write(Self.workflow, ".saturn/workflows/feature-delivery.yaml", in: root)

        let config = ProjectConfigLoader.load(repository: root)

        #expect(config.issues.isEmpty, "\(config.issues)")
        #expect(config.workflow("feature-delivery")?.steps.map(\.agent) == [.lead, .builder, .builder, .checker, .checker])
        #expect(!exists(".saturn/legacy-roles", in: root))
        #expect(!exists(".claude/skills", in: root))
        #expect(!config.migrationNotices.isEmpty)
        #expect(ProjectConfigLoader.load(repository: root).migrationNotices.isEmpty)
    }

    @Test func anExistingLegacyFolderKeepsBothCopies() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old", ".saturn/legacy-roles/payments.yaml", in: root)

        try RoleMigration.migrate(repository: root)

        #expect(try read(".saturn/legacy-roles/payments.yaml", in: root) == "old")
        #expect(try read(".saturn/legacy-roles/payments-2.yaml", in: root) == Self.payments)
        #expect(!exists(".saturn/roles", in: root))
    }

    @MainActor
    @Test func thisRepositorysOldConfigLoadsCleanlyTwiceAndDryRuns() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in RepositoryFixture.roles { try write(text, ".saturn/roles/\(name).yaml", in: root) }
        for (name, text) in RepositoryFixture.workflows { try write(text, ".saturn/workflows/\(name).yaml", in: root) }
        try write(Self.payments, ".saturn/roles/payments.yaml", in: root)

        let first = ProjectConfigLoader.load(repository: root)
        #expect(first.issues.isEmpty, "\(first.issues)")
        #expect(!first.migrationNotices.isEmpty)
        let feature = try #require(first.workflow("feature-delivery"))
        #expect(feature.steps.map(\.agent) == [.lead, .builder, .lead, .checker, nil])
        #expect(feature.steps.compactMap(\.model) == ["opus", "opus", "opus", "opus"])
        #expect(try #require(first.workflow("small-task")).steps.map(\.agent) == [.builder, .checker, nil])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".claude/skills").path)) == ["payments", "qa-engineer"])
        #expect(try read(".claude/skills/qa-engineer/SKILL.md", in: root).contains("run the app to make sure it’s working"))

        let snapshot = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let second = ProjectConfigLoader.load(repository: root)
        #expect(second.issues.isEmpty)
        #expect(second.migrationNotices.isEmpty)
        #expect(second.workflows == first.workflows)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == snapshot)

        for workflow in second.workflows {
            let report = try await DryRun.run(workflow, script: DryRunScript.happyPath(for: workflow))
            #expect(report.status == .succeeded, "\(workflow.id)")
            let visited = report.steps.compactMap { workflow.step($0.stepId) }.filter { $0.type == .agent || $0.type == .spawn }
            #expect(visited.allSatisfy { $0.agent != nil }, "\(workflow.id)")
        }
    }
}

enum RepositoryFixture {
    static let roles: [(String, String)] = [
        ("claude-code", RoleMigrationTests.claudeCode),
        ("pr-reviewer", """
        name: PR Reviewer
        model: opus
        edits_code: false
        can_spawn: false
        prompt: 'You review code like a senior engineer: correctness first, then tests, then clarity. Read the diff against

          the base branch and the task. Approve only what you would merge; otherwise request specific changes.

          '
        """),
        ("project-manager", """
        name: Project Manager
        model: opus
        edits_code: false
        can_spawn: true
        prompt: 'You are the Project Manager. Your job is to talk with the user and shape the work before anyone builds it.

          Clarify the goal behind each request. When requirements are ambiguous, ask questions instead of guessing.

          Define the next steps, raise ideas and trade-offs, and break the work into well-scoped tasks that can be

          handed to the right roles. Refine proposals with the user until they are ready to start.

          Do not write code and do not review branches. Stay in conversation and keep the plan clear and short.

          '
        """),
        ("qa-engineer", """
        name: QA Engineer
        description: Tests the combined work end to end
        model: opus
        edits_code: false
        can_spawn: false
        permission_profile: app_testing
        prompt: 'You are the QA engineer. You work in a temporary worktree where every branch of this run has been merged.

          Run the project''s test suites and make sure the task really works before approving, run the app to make sure it’s working. Report failures with the exact command,

          the output, and which task they belong to. Never fix code yourself.

          '
        """),
        ("tech-lead", RoleMigrationTests.techLead),
    ]

    static let workflows: [(String, String)] = [
        ("feature-delivery", LegacyWorkflows.featureDelivery),
        ("small-task", LegacyWorkflows.smallTask),
    ]
}
