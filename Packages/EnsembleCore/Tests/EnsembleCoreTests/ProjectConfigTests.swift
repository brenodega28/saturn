import Foundation
import Testing
@testable import EnsembleCore

@Suite struct ProjectConfigTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func defaultsInstallLoadAndValidateCleanly() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        try ProjectConfigLoader.installDefaults(repository: repository)
        let config = ProjectConfigLoader.load(repository: repository)

        #expect(config.issues.isEmpty)
        #expect(config.roles.map(\.id) == ["claude-code", "pr-reviewer", "project-manager", "qa-engineer", "tech-lead"])
        #expect(config.role("tech-lead")?.canSpawn == true)
        #expect(config.role("project-manager")?.canSpawn == true)
        #expect(config.role("project-manager")?.editsCode == false)
        #expect(config.leadRoles.map(\.id) == ["tech-lead", "project-manager"])
        #expect(config.role("qa-engineer")?.editsCode == false)
        let feature = try #require(config.workflow("feature-delivery"))
        #expect(feature.steps.map(\.id) == ["plan", "build", "review", "qa", "approve"])
        #expect(feature.step("review")?.routes["changes_requested"] == WorkflowRoute(to: "build", maxLoops: 3))
        #expect(feature.step("approve")?.routes["approved"]?.to == WorkflowDefinition.endStepID)
        #expect(feature.end.action == .pullRequest)
        #expect(FileManager.default.fileExists(atPath: repository.appending(path: ".ensemble/.gitignore").path))
    }

    @Test func rolesAndWorkflowsRoundTripThroughYAML() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let role = RoleDefinition(id: "django-developer", name: "Django Developer", icon: "django", color: "django", prompt: "Build Django.\nCarefully.", skills: ["django-developer"], docs: ["AGENTS.md"], budgetPerRun: 3)
        let workflow = WorkflowDefinition(id: "hotfix", name: "Hotfix", steps: [
            WorkflowStep(id: "fix", type: .agent, role: "django-developer", next: "approve", position: CanvasPosition(x: 10, y: 20)),
            WorkflowStep(id: "approve", type: .approval, routes: ["approved": WorkflowRoute(to: "end"), "changes_requested": WorkflowRoute(to: "fix", maxLoops: 2)]),
        ], end: WorkflowEnd(action: .merge))

        try ProjectConfigLoader.write(role, repository: repository)
        try ProjectConfigLoader.write(workflow, repository: repository)
        let config = ProjectConfigLoader.load(repository: repository)

        #expect(config.issues.isEmpty)
        #expect(config.roles == [role])
        #expect(config.workflows == [workflow])
    }

    @Test func reportsBrokenFilesAndBadReferences() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let roles = repository.appending(path: ".ensemble/roles")
        let workflows = repository.appending(path: ".ensemble/workflows")
        try FileManager.default.createDirectory(at: roles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try "description: no name\n".write(to: roles.appending(path: "broken.yaml"), atomically: true, encoding: .utf8)
        try "name: Lead\nedits_code: true\ncan_spawn: true\nmodel: gpt\n".write(to: roles.appending(path: "lead.yaml"), atomically: true, encoding: .utf8)
        try """
        name: Bad
        steps:
          - id: a
            type: agent
            role: ghost
            next: nowhere
          - id: c
            type: condition
        """.write(to: workflows.appending(path: "bad.yaml"), atomically: true, encoding: .utf8)

        let messages = ProjectConfigLoader.load(repository: repository).issues.map { "\($0.file): \($0.message)" }

        #expect(messages.contains(".ensemble/roles/broken.yaml: missing “name”"))
        #expect(messages.contains(".ensemble/roles/lead.yaml: model “gpt” isn’t a known model"))
        #expect(messages.contains(".ensemble/roles/lead.yaml: a role can’t both spawn agents and edit code"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.a: role “ghost” doesn’t exist"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.a: routes to unknown step “nowhere”"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.c: needs a condition"))
    }

    @Test func docsResolvePerRole() throws {
        let lead = RoleDefinition(id: "lead", name: "Lead", editsCode: false, canSpawn: true)
        let dev = RoleDefinition(id: "dev", name: "Dev", docs: ["docs/API.md"])
        let qa = RoleDefinition(id: "qa", name: "QA", editsCode: false)
        let config = ProjectConfig(roles: [lead, dev, qa], docs: DocsIndex(docs: [
            DocEntry(title: "AGENTS.md", path: "AGENTS.md"),
            DocEntry(title: "Roadmap", path: "docs/ROADMAP.md", readers: .leads),
            DocEntry(title: "Payments rules", prompt: "Pin payments changes.", readers: .coding),
            DocEntry(title: "Old", path: "OLD.md", enabled: false),
            DocEntry(title: "QA notes", path: "QA.md", readers: .roles(["qa"])),
        ]))

        #expect(config.docs(for: lead).map(\.title) == ["AGENTS.md", "Roadmap"])
        #expect(config.docs(for: dev).map(\.title) == ["AGENTS.md", "Payments rules", "API.md"])
        #expect(config.docs(for: qa).map(\.title) == ["AGENTS.md", "QA notes"])
    }

    @Test func handoffToolsDecodeArguments() throws {
        let plan = try HandoffTool.submitPlan.decode(.object([
            "summary": .string("Split it"),
            "tasks": .array([.object(["title": .string("API"), "role": .string("claude-code"), "files": .array([.string("api/")])])]),
        ]))
        guard case .plan(let decoded) = plan else { Issue.record("expected plan"); return }
        #expect(decoded.tasks.first?.count == 1)
        #expect(decoded.tasks.first?.files == ["api/"])

        let pin = try HandoffTool.createPin.decode(.object([
            "file": .string("a.py"), "start_line": .number(3), "end_line": .number(9),
            "title": .string("Money"), "explanation": .string("Rounding"),
        ]))
        #expect(pin == .pin(PinDraft(file: "a.py", startLine: 3, endLine: 9, title: "Money", explanation: "Rounding")))
        #expect(throws: HandoffError.missing("question")) { try HandoffTool.askHuman.decode(.object([:])) }
    }
}

@Suite struct YAMLNumberTests {
    @Test func writesReadableNumbers() throws {
        let workflow = WorkflowDefinition(id: "w", name: "W", budget: 20, steps: [
            WorkflowStep(id: "a", type: .agent, role: "r", budget: 2.5, position: CanvasPosition(x: 400.4, y: 180)),
        ])
        let yaml = try ProjectConfigLoader.encodeYAML(workflow)
        #expect(yaml.contains("budget: 20\n"))
        #expect(yaml.contains("budget: 2.5\n"))
        #expect(yaml.contains("x: 400\n"))
        #expect(!yaml.contains("e+"))
    }
}
