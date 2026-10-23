import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct WorkflowDriverTests {
    struct Setup {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let engine: RunEngine
        let project: Project
        let config: ProjectConfig
    }

    func makeSetup(endAction: EndAction = .merge) async throws -> Setup {
        let harness = try await AgentHarness.make(mode: "workflow")
        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        var feature = try #require(ProjectConfigLoader.load(repository: harness.repo.root).workflow("feature-delivery"))
        feature.end = WorkflowEnd(action: endAction, cleanUpWorktrees: true)
        try ProjectConfigLoader.write(feature, repository: harness.repo.root)
        try await harness.repo.git.run(["add", ".ensemble"], in: harness.repo.root)
        try await harness.repo.git.run(["commit", "-m", "Add Ensemble config"], in: harness.repo.root)

        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.pollInterval = .milliseconds(20)
        let engine = RunEngine(database: harness.database, driver: driver)
        let project = try #require(try harness.database.project(id: harness.project.id!))
        return Setup(harness: harness, driver: driver, engine: engine, project: project, config: ProjectConfigLoader.load(repository: harness.repo.root))
    }

    func startRun(_ setup: Setup, title: String = "Add alpha and beta") throws -> Run {
        let now = Date()
        let task = try setup.harness.database.insert(ProjectTask(
            projectId: setup.project.id!, title: title, body: "Two files, please.", source: .chat,
            status: .incoming, createdAt: now, updatedAt: now
        ))
        return try setup.engine.start(task: task, workflow: try #require(setup.config.workflow("feature-delivery")), project: setup.project)
    }

    func waitForHold(_ setup: Setup, run: Run, _ reason: HoldReason, timeout: Duration = .seconds(30)) async throws {
        try await waitUntil(timeout: timeout) { setup.engine.holds[run.id!]?.reason == reason }
    }

    @Test func featureDeliveryRunsEndToEndWithAReviewLoop() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        try "".write(to: setup.harness.bin.appending(path: "reject"), atomically: true, encoding: .utf8)

        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)

        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        #expect(plan.tasks.map(\.title) == ["Add alpha", "Add beta"])

        try setup.engine.approvePlan(run, plan: plan)
        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let steps = try setup.harness.database.runSteps(runId: run.id!)
        #expect(steps.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve"])
        #expect(steps.filter { $0.stepId == "review" }.map(\.outcome) == ["changes_requested", "approved"])
        #expect(steps.first { $0.stepId == "qa" }?.outcome == "passed")

        let agents = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id }
        #expect(agents.filter { $0.role == "tech-lead" }.count == 1)
        #expect(agents.filter { $0.planTaskId != nil }.count == 2)
        #expect(agents.filter { $0.role == "qa-engineer" }.count == 1)

        let alphaBuilder = try #require(agents.first { $0.planTaskId != nil && $0.task == "Add alpha" })
        let alpha = try String(contentsOf: alphaBuilder.worktreeURL!.appending(path: "alpha.txt"), encoding: .utf8)
        #expect(alpha.split(separator: "\n").count == 2)
        let betaBuilder = try #require(agents.first { $0.planTaskId != nil && $0.task == "Add beta" })
        let beta = try String(contentsOf: betaBuilder.worktreeURL!.appending(path: "beta.txt"), encoding: .utf8)
        #expect(beta.split(separator: "\n").count == 1)

        let pins = try await setup.harness.database.writer.read { db in try Pin.fetchAll(db) }
        #expect(Set(pins.map(\.file)) == ["alpha.txt", "beta.txt"])
        #expect(pins.allSatisfy { $0.runId == run.id })

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }

        let main = try await setup.harness.repo.git.run(["ls-tree", "--name-only", "main"], in: setup.harness.repo.root)
        #expect(main.contains("alpha.txt"))
        #expect(main.contains("beta.txt"))
        #expect(try await setup.harness.repo.manager.list().isEmpty)
        #expect(try setup.harness.database.task(id: run.taskId)?.status == .done)
    }

    @Test func questionsWaitForTheUsersAnswer() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let lead = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.role == "tech-lead" })

        let reply = try await setup.driver.receive(.question("Which database?"), from: lead.id!)

        #expect(reply.contains("End your turn"))
        let open = try setup.harness.database.openInboxItems(projectId: setup.project.id!).filter { $0.kind == .question }
        #expect(open.map(\.body) == ["Which database?"])
        #expect(open.first?.agentId == lead.id)
    }

    @Test func plansWithUnknownRolesAreRejectedToTheAgent() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let lead = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.role == "tech-lead" })

        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.plan(Plan(summary: "x", tasks: [PlanTask(title: "t", role: "rust-wizard")])), from: lead.id!)
        }
    }

    @Test func conflictingBranchesAreResolvedByTheBuilderAfterQAFails() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        var plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        plan.tasks = plan.tasks.map { var task = $0; task.title = "Add alpha"; return task }
        try setup.engine.approvePlan(run, plan: plan)

        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let steps = try setup.harness.database.runSteps(runId: run.id!)
        #expect(steps.filter { $0.stepId == "qa" }.map(\.outcome) == ["failed", "passed"])
        let firstQA = try #require(steps.first { $0.stepId == "qa" })
        let verdict = try #require(firstQA.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.verdict)
        #expect(verdict.issues.first?.description.contains("alpha.txt") == true)
        #expect(try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.role == "qa-engineer" }.count == 1)

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }
        let alpha = try await setup.harness.repo.git.run(["show", "main:alpha.txt"], in: setup.harness.repo.root)
        #expect(alpha.split(separator: "\n").count == 2)
        #expect(!alpha.contains("<<<<<<<"))
    }
}
