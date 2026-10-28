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
        #expect(config.migrationNotices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repository.appending(path: ".ensemble/roles").path))
        #expect(config.roles.map(\.id) == ["lead", "builder", "checker"])
        #expect(config.roles.map(\.name) == ["Lead", "Builder", "Checker"])
        #expect(config.role("lead")?.canSpawn == true)
        #expect(config.role("lead")?.editsCode == false)
        #expect(config.role("lead")?.model == "opus")
        #expect(config.role("builder")?.editsCode == true)
        #expect(config.role("checker")?.editsCode == false)
        #expect(config.role("checker")?.canSpawn == false)
        #expect(config.role("tech-lead") == nil)
        let feature = try #require(config.workflow("feature-delivery"))
        #expect(feature.steps.map(\.id) == ["plan", "build", "checks", "gates", "review", "approve"])
        #expect(feature.steps.map(\.type) == [.agent, .spawn, .check, .gates, .agent, .approval])
        #expect(feature.steps.map(\.agent) == [.lead, .builder, nil, nil, .lead, nil])
        #expect(feature.step("plan")?.model == "opus")
        #expect(feature.step("gates")?.routes["changes_requested"]?.to == "build")
        #expect(feature.step("review")?.routes["changes_requested"] == WorkflowRoute(to: "build", maxLoops: 1))
        let small = try #require(config.workflow("small-task"))
        #expect(small.steps.map(\.id) == ["build", "checks", "gates", "review", "approve"])
        #expect(small.step("review")?.agent == .checker)
        for template in CrewTemplates.bundled {
            let templateRepository = try makeRepository()
            defer { try? FileManager.default.removeItem(at: templateRepository) }
            try template.install(in: templateRepository)
            let installed = ProjectConfigLoader.load(repository: templateRepository)
            #expect(installed.issues.isEmpty, "\(template.id): \(installed.issues)")
            #expect(installed.workflows.allSatisfy { $0.steps.contains { $0.type == .check } && $0.steps.contains { $0.type == .gates } })
        }
        #expect(feature.step("approve")?.routes["approved"]?.to == WorkflowDefinition.endStepID)
        #expect(feature.end.action == .pullRequest)
        #expect(FileManager.default.fileExists(atPath: repository.appending(path: ".ensemble/.gitignore").path))
    }

    @Test func workflowsRoundTripThroughYAMLWithAgentAndModel() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let workflow = WorkflowDefinition(id: "hotfix", name: "Hotfix", steps: [
            WorkflowStep(id: "fix", type: .agent, agent: .builder, model: "haiku", next: "approve", position: CanvasPosition(x: 10, y: 20)),
            WorkflowStep(id: "approve", type: .approval, routes: ["approved": WorkflowRoute(to: "end"), "changes_requested": WorkflowRoute(to: "fix", maxLoops: 2)]),
        ], end: WorkflowEnd(action: .merge))

        try ProjectConfigLoader.write(workflow, repository: repository)
        let yaml = try String(contentsOf: repository.appending(path: ".ensemble/workflows/hotfix.yaml"), encoding: .utf8)
        let config = ProjectConfigLoader.load(repository: repository)

        #expect(yaml.contains("agent: builder\n"))
        #expect(yaml.contains("model: haiku\n"))
        #expect(!yaml.contains("role:"))
        #expect(config.issues.isEmpty)
        #expect(config.workflows == [workflow])
    }

    @Test func reportsBadAgentsModelsAndReferences() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let workflows = repository.appending(path: ".ensemble/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try """
        name: Bad
        steps:
          - id: a
            type: agent
            agent: builder
            model: gpt
            next: nowhere
          - id: b
            type: agent
          - id: s
            type: spawn
            agent: checker
          - id: c
            type: condition
        """.write(to: workflows.appending(path: "bad.yaml"), atomically: true, encoding: .utf8)
        try """
        name: Typo
        steps:
          - id: a
            type: agent
            agent: reviewer
        """.write(to: workflows.appending(path: "typo.yaml"), atomically: true, encoding: .utf8)

        let messages = ProjectConfigLoader.load(repository: repository).issues.map { "\($0.file): \($0.message)" }

        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.a: model “gpt” isn’t a known model"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.a: routes to unknown step “nowhere”"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.b: needs an agent: one of lead, builder, checker"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.s: spawn steps start builders; use agent: builder"))
        #expect(messages.contains(".ensemble/workflows/bad.yaml: steps.c: needs a condition"))
        #expect(messages.contains { $0.hasPrefix(".ensemble/workflows/typo.yaml: steps.[0].agent:") || $0.hasPrefix(".ensemble/workflows/typo.yaml: steps[0].agent:") || ($0.hasPrefix(".ensemble/workflows/typo.yaml") && $0.contains("reviewer")) })
    }

    @Test func docsResolvePerKind() throws {
        let config = ProjectConfig(docs: DocsIndex(docs: [
            DocEntry(title: "AGENTS.md", path: "AGENTS.md"),
            DocEntry(title: "Roadmap", path: "docs/ROADMAP.md", readers: .leads),
            DocEntry(title: "Payments rules", prompt: "Pin payments changes.", readers: .coding),
            DocEntry(title: "Old", path: "OLD.md", enabled: false),
            DocEntry(title: "QA notes", path: "QA.md", readers: .roles(["qa-engineer"])),
            DocEntry(title: "Shared", path: "S.md", readers: .roles(["django-developer", "lead"])),
        ]))

        #expect(config.docs(for: .lead).map(\.title) == ["AGENTS.md", "Roadmap", "Shared"])
        #expect(config.docs(for: .builder).map(\.title) == ["AGENTS.md", "Payments rules", "Shared"])
        #expect(config.docs(for: .checker).map(\.title) == ["AGENTS.md", "QA notes"])
    }

    @Test func handoffToolsDecodeArguments() throws {
        let plan = try HandoffTool.submitPlan.decode(.object([
            "summary": .string("Split it"),
            "tasks": .array([
                .object(["title": .string("API"), "agent": .string("builder"), "skills": .array([.string("django-developer")]), "files": .array([.string("api/")])]),
                .object(["title": .string("UI")]),
            ]),
        ]))
        guard case .plan(let decoded) = plan else { Issue.record("expected plan"); return }
        #expect(decoded.tasks.first?.files == ["api/"])
        #expect(decoded.tasks.first?.skills == ["django-developer"])
        #expect(decoded.tasks.map(\.agent) == [.builder, .builder])

        let pin = try HandoffTool.createPin.decode(.object([
            "file": .string("a.py"), "start_line": .number(3), "end_line": .number(9),
            "title": .string("Money"), "explanation": .string("Rounding"),
        ]))
        #expect(pin == .pin(PinDraft(file: "a.py", startLine: 3, endLine: 9, title: "Money", explanation: "Rounding")))
        #expect(throws: HandoffError.missing("question")) { try HandoffTool.askHuman.decode(.object([:])) }
    }

    @Test func planTasksDecodeLegacyRolesByKindAndEncodeAgent() throws {
        let json = """
        {"summary": "Old", "tasks": [
          {"id": "a", "title": "API", "role": "django-developer", "files": ["api/"]},
          {"id": "b", "title": "Review", "role": "pr-reviewer"},
          {"id": "c", "title": "Plan", "role": "tech-lead", "count": 2}
        ]}
        """
        let plan = try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        #expect(plan.tasks.map(\.agent) == [.builder, .checker, .lead])
        #expect(plan.tasks.allSatisfy { $0.skills.isEmpty })
        #expect(plan.tasks.first?.files == ["api/"])

        let encoded = String(decoding: try JSONEncoder().encode(plan.tasks[0]), as: UTF8.self)
        #expect(encoded.contains("\"agent\":\"builder\""))
        #expect(!encoded.contains("\"role\""))
        #expect(try JSONDecoder().decode(PlanTask.self, from: Data(encoded.utf8)) == plan.tasks[0])
    }

    @Test func legacyStepRolesDecodeToKindsByName() throws {
        let workflow = try YAMLWorkflow.decode(LegacyWorkflows.featureDelivery)
        #expect(workflow.steps.map(\.agent) == [.lead, .builder, .lead, .checker, nil])
        #expect(workflow.steps.compactMap(\.legacyRole) == ["tech-lead", "claude-code", "tech-lead", "qa-engineer"])
    }

    @Test func permissionsResolveByKind() {
        let permissions = PermissionsConfig()
        #expect(permissions.resolve(for: .lead, readOnly: true).id == "lead")
        #expect(permissions.resolve(for: .lead, readOnly: false).id == "developer")
        #expect(permissions.resolve(for: .builder).id == "developer")
        #expect(permissions.resolve(for: .checker).id == "reviewer")
        #expect(permissions.resolve(for: nil, readOnly: true).id == "reviewer")
        #expect(permissions.resolve(for: nil).id == "developer")
        for kind in [AgentKind.lead, .checker] {
            let policy = PermissionPolicy(profile: permissions.resolve(for: kind, readOnly: true), readOnly: true)
            #expect(policy.level(.editFiles) == .never)
            #expect(policy.level(.gitPush) == .never)
        }
    }
}

@Suite struct YAMLNumberTests {
    @Test func writesReadableNumbers() throws {
        let workflow = WorkflowDefinition(id: "w", name: "W", budget: 20, steps: [
            WorkflowStep(id: "a", type: .agent, agent: .builder, budget: 2.5, position: CanvasPosition(x: 400.4, y: 180)),
        ])
        let yaml = try ProjectConfigLoader.encodeYAML(workflow)
        #expect(yaml.contains("budget: 20\n"))
        #expect(yaml.contains("budget: 2.5\n"))
        #expect(yaml.contains("x: 400\n"))
        #expect(!yaml.contains("e+"))
    }
}
