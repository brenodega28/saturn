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

    @Test func scanFindsTheStackAndSuggestsMatchingSkills() throws {
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
        #expect(scan.skillReasons["django-developer"] == "backend/")
        #expect(scan.skillReasons["react-developer"] == "frontend/")
        #expect(scan.suggestedSkills == ["django-developer", "react-developer"])
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
        #expect(config.roles.map(\.id) == ["lead", "builder", "checker"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".ensemble/roles").path))
        #expect(SkillLibrary.installedSkills(in: root, home: root).isSuperset(of: ["django-developer", "react-developer"]))
        #expect(config.workflows.map(\.id).sorted() == ["feature-delivery", "hotfix", "small-task"])
        #expect(config.workflows.allSatisfy { $0.end.action == .push && $0.budget == 8 })
        #expect(config.preferences == ProjectPreferences(baseBranch: "develop", branchPrefix: "agents", defaultWorkflow: "feature-delivery", approvePlans: false))
        #expect(config.permissions.profile("developer")?.level(.network) == .allow)
        #expect(config.permissions.profile("developer")?.level(.installPackages) == .ask)
        #expect(config.checks?.checks.contains { $0.kind == .test } == true)
        #expect(config.docs.docs.compactMap(\.path) == ["AGENTS.md", "docs/ROADMAP.md"])
    }

    @Test func setupInstallsOnlyTheSkillsYouKeepAndWorkflowsUseKinds() throws {
        let root = try djangoReactRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appending(path: ".claude/skills/react-developer")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "mine".write(to: existing.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        var plan = ProjectSetupPlan.recommended(for: ProjectScanner.scanFiles(repository: root))
        plan.skills = ["react-developer"]

        try plan.apply(to: root)
        let config = ProjectConfigLoader.load(repository: root)

        #expect(config.issues.isEmpty, "\(config.issues)")
        #expect(SkillLibrary.installedSkills(in: root, home: root) == ["react-developer"])
        #expect(try String(contentsOf: existing.appending(path: "notes.md"), encoding: .utf8) == "mine")
        let feature = try #require(config.workflow("feature-delivery"))
        #expect(feature.step("plan")?.agent == .lead)
        #expect(feature.step("build")?.agent == .builder)
        #expect(try #require(config.workflow("small-task")).step("review")?.agent == .checker)
        #expect(try #require(config.workflow("hotfix")).step("build")?.agent == .builder)
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
        #expect(guide.contains("- `small-task`: Small task v3 (the default"))
        #expect(!guide.contains("- `hotfix`: Hotfix v1 (the default"))
    }
}

extension ProjectSetupTests {
    @Test func unknownDefaultsAreReported() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-prefs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectConfigLoader.installDefaults(repository: root)
        try ProjectConfigLoader.write(ProjectPreferences(defaultWorkflow: "nope"), repository: root)

        let messages = ProjectConfigLoader.load(repository: root).issues.map(\.message)
        #expect(messages == ["default workflow “nope” doesn’t exist"])
    }

    @Test func templatesShipWorkflowsAndRecommendedSkillsWithoutRoles() throws {
        let templates = CrewTemplates.bundled
        #expect(Set(templates.map(\.id)) == ["django-react", "led-squad", "solo-with-review"])
        let django = try #require(CrewTemplates.template("django-react"))
        #expect(django.recommendedSkills == ["django-developer", "react-developer"])
        #expect(django.bundledSkills.map(\.name) == ["django-developer", "react-developer"])
        #expect(ProjectSetup.skillCatalog.map(\.name) == ["django-developer", "react-developer"])

        for template in templates {
            let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-template-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            try template.install(in: root)
            let config = ProjectConfigLoader.load(repository: root)
            #expect(config.issues.isEmpty, "\(template.id): \(config.issues)")
            #expect(config.migrationNotices.isEmpty, "\(template.id)")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".ensemble/roles").path))
            #expect(config.workflows.map(\.id) == template.workflows)
            #expect(config.workflows.flatMap(\.steps).filter { $0.type == .agent || $0.type == .spawn }.allSatisfy { $0.agent != nil && $0.model != nil })
            #expect(SkillLibrary.installedSkills(in: root, home: root) == Set(template.bundledSkills.map(\.name)))
        }
    }
}
