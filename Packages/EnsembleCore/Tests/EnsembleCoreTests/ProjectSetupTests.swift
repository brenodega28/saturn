import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct ProjectSetupTests {
    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func djangoReactRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try write("import django\n", to: "backend/manage.py", in: root)
        try write(#"{"dependencies": {"react": "18"}, "devDependencies": {"vite": "5", "vitest": "1"}, "scripts": {"test": "vitest run", "lint": "eslint ."}}"#, to: "frontend/package.json", in: root)
        try write("[pytest]\n", to: "pytest.ini", in: root)
        try write("def test_ok(): pass\n", to: "tests/test_refunds.py", in: root)
        try write("services:\n  db:\n    image: postgres:16\n", to: "docker-compose.yml", in: root)
        try write("# Agents\n", to: "AGENTS.md", in: root)
        try write("# Roadmap\n", to: "docs/ROADMAP.md", in: root)
        return root
    }

    @Test func scanFindsTheStackAndSuggestsMatchingRoles() throws {
        let root = try djangoReactRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = ProjectScanner.scanFiles(repository: root)
        let names = scan.found.map(\.name)
        #expect(names.contains("Django"))
        #expect(names.contains("React + Vite"))
        #expect(names.contains("pytest"))
        #expect(names.contains("Vitest"))
        #expect(names.contains("PostgreSQL"))
        #expect(names.contains("AGENTS.md"))
        #expect(scan.roleReasons["django-developer"] == "backend/")
        #expect(scan.roleReasons["react-developer"] == "frontend/")
        #expect(scan.roleReasons["qa-engineer"] == "tests/")
        #expect(scan.suggestedRoleIDs == ["tech-lead", "django-developer", "react-developer", "claude-code", "pr-reviewer", "qa-engineer"])
        #expect(scan.docs == ["AGENTS.md", "docs/ROADMAP.md"])
    }

    @Test func recommendedSetupWritesAValidConfig() throws {
        let root = try djangoReactRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        var plan = ProjectSetupPlan.recommended(for: ProjectScanner.scanFiles(repository: root))
        plan.baseBranch = "develop"
        plan.branchPrefix = "agents/"
        plan.endAction = .push
        plan.approvePlans = false
        plan.networkWithoutAsking = true

        try plan.apply(to: root)
        let config = ProjectConfigLoader.load(repository: root)

        #expect(config.issues.isEmpty, "\(config.issues)")
        #expect(Set(config.roles.map(\.id)) == ["tech-lead", "django-developer", "react-developer", "claude-code", "pr-reviewer", "qa-engineer"])
        #expect(config.workflows.map(\.id).sorted() == ["feature-delivery", "hotfix", "small-task"])
        #expect(config.workflows.allSatisfy { $0.end.action == .push && $0.budget == 8 })
        #expect(config.preferences == ProjectPreferences(baseBranch: "develop", branchPrefix: "agents", defaultLead: "tech-lead", defaultWorkflow: "feature-delivery", approvePlans: false))
        #expect(config.permissions.profile("developer")?.level(.network) == .allow)
        #expect(config.permissions.profile("developer")?.level(.installPackages) == .ask)
        #expect(config.checks?.checks.contains { $0.kind == .test } == true)
        #expect(config.docs.docs.compactMap(\.path) == ["AGENTS.md", "docs/ROADMAP.md"])
    }

    @Test func workflowsFollowTheRolesYouKeep() throws {
        let root = try djangoReactRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        var plan = ProjectSetupPlan.recommended(for: ProjectScanner.scanFiles(repository: root))
        let catalog = ProjectSetup.roleCatalog
        plan.roles = ["project-manager", "django-developer"].compactMap { id in catalog.first { $0.id == id } }
        plan.leadRole = "project-manager"

        try plan.apply(to: root)
        let config = ProjectConfigLoader.load(repository: root)

        #expect(config.issues.isEmpty, "\(config.issues)")
        let feature = try #require(config.workflow("feature-delivery"))
        #expect(feature.step("plan")?.role == "project-manager")
        #expect(feature.step("build")?.role == "django-developer")
        #expect(feature.step("review")?.role == "project-manager")
        #expect(try #require(config.workflow("small-task")).step("build")?.role == "django-developer")
    }

    @Test func agentsBranchFromThePreferredBaseWithThePrefix() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        try await repo.git.run(["branch", "develop"], in: repo.root)
        try ProjectConfigLoader.write(ProjectPreferences(baseBranch: "develop", branchPrefix: "agents"), repository: repo.root)

        #expect(try await repo.git.baseBranch(of: repo.root) == "develop")
        let manager = WorktreeManager(repository: repo.root, git: repo.git)
        #expect(try manager.branchName(agent: "Dev 1", slug: "refunds") == "agents/dev-1/refunds")

        try ProjectConfigLoader.write(ProjectPreferences(baseBranch: "gone"), repository: repo.root)
        #expect(try await repo.git.baseBranch(of: repo.root) == repo.git.currentBranch(in: repo.root))
    }

    @Test func plansStartWithoutApprovalWhenTheProjectSaysSo() async throws {
        let h = try WorkflowHarness.make()
        defer { h.cleanUp() }
        try ProjectConfigLoader.write(ProjectPreferences(approvePlans: false), repository: h.repository)
        h.driver.script("plan", .result(.plan(WorkflowHarness.plan, costUSD: 0.5)))
        h.driver.script("build", WorkflowHarness.done("Built", cost: 1))
        h.driver.script("review", WorkflowHarness.verdict(StepOutcome.approved, "Fine", cost: 0.25))
        h.driver.script("qa", WorkflowHarness.verdict(StepOutcome.passed, "Green", cost: 0.25))

        let id = try await h.start(try h.workflow("feature-delivery"))
        await h.settle(id)

        #expect(try h.hold(id)?.reason == .approval)
        #expect(try h.database.openInboxItems(projectId: try #require(h.project.id)).map(\.kind) == [.approval])
    }

    @Test func leadGuideMarksTheDefaultWorkflow() {
        let workflows = ProjectSetup.workflowCatalog
        let guide = AgentRuntime.leadChatGuide(workflows: workflows, defaultWorkflow: "small-task")
        #expect(guide.contains("- `small-task`: Small task v2 (the default"))
        #expect(!guide.contains("- `hotfix`: Hotfix v1 (the default"))
    }
}

extension ProjectSetupTests {
    @Test func theChosenLeadAnswersFirst() {
        let roles = ProjectSetup.roleCatalog.filter(\.canSpawn)
        var config = ProjectConfig(roles: roles)
        #expect(config.leadRoles.first?.id == ProjectConfig.defaultLeadID)
        config.preferences.defaultLead = "project-manager"
        #expect(config.leadRoles.first?.id == "project-manager")
        config.preferences.defaultLead = "missing"
        #expect(config.leadRoles.first?.id == ProjectConfig.defaultLeadID)
    }
}

extension ProjectSetupTests {
    @Test func unknownDefaultsAreReported() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-prefs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectConfigLoader.installDefaults(repository: root)
        try ProjectConfigLoader.write(ProjectPreferences(defaultLead: "claude-code", defaultWorkflow: "nope"), repository: root)

        let messages = ProjectConfigLoader.load(repository: root).issues.map(\.message)
        #expect(messages.contains("default lead “claude-code” isn’t a role that can spawn agents"))
        #expect(messages.contains("default workflow “nope” doesn’t exist"))
    }
}
