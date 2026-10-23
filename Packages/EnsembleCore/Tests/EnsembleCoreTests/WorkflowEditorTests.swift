import Foundation
import Testing
@testable import EnsembleCore

@MainActor
struct DryRunTests {
    private func defaults(_ id: String) throws -> WorkflowDefinition {
        let harness = try WorkflowHarness.make()
        defer { harness.cleanUp() }
        return try harness.workflow(id)
    }

    @Test func happyPathRunsEveryStepOnceAndFinishes() async throws {
        let workflow = try defaults("feature-delivery")
        let report = try await DryRun.run(workflow, script: .happyPath(for: workflow))
        #expect(report.status == .succeeded)
        #expect(report.path == [WorkflowDefinition.triggerNodeID, "plan", "build", "review", "qa", "approve", "end"])
        #expect(report.steps.map(\.outcome) == ["done", "done", "approved", "passed", "approved", "done"])
        #expect(report.notes.contains("Plan from “Plan & split the task” approved automatically."))
        #expect(report.transitions.contains(DryRunTransition(from: "qa", to: "approve")))
    }

    @Test func scriptedOutcomeLoopsBackOnceThenFollowsTheHappyPath() async throws {
        let workflow = try defaults("feature-delivery")
        var script = DryRunScript.happyPath(for: workflow)
        script.outcomes["review"] = [StepOutcome.changesRequested]
        let report = try await DryRun.run(workflow, script: script)
        #expect(report.status == .succeeded)
        #expect(report.steps.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve", "end"])
        #expect(report.visits(of: "build") == 2)
        #expect(report.transitions.contains(DryRunTransition(from: "review", to: "build")))
    }

    @Test func approvalsResolveFromTheScript() async throws {
        let workflow = try defaults("small-task")
        var script = DryRunScript.happyPath(for: workflow)
        script.outcomes["approve"] = [StepOutcome.changesRequested]
        let report = try await DryRun.run(workflow, script: script)
        #expect(report.status == .succeeded)
        #expect(report.steps.map(\.stepId) == ["build", "review", "approve", "build", "review", "approve", "end"])
        #expect(report.steps[2].outcome == StepOutcome.changesRequested)
    }

    @Test func loopLimitStopsTheRun() async throws {
        let workflow = try defaults("small-task")
        var script = DryRunScript.happyPath(for: workflow)
        script.outcomes["review"] = Array(repeating: StepOutcome.changesRequested, count: 5)
        let report = try await DryRun.run(workflow, script: script)
        #expect(report.status == .failed)
        #expect(report.steps.filter { $0.stepId == "review" }.count == 3)
        #expect(report.notes.contains("“Review” hit its loop limit; the run stops here."))
        #expect(!report.visitedNodes.contains("end"))
    }

    @Test func conditionsUseTheSampleLabelsAndDiff() async throws {
        var workflow = WorkflowDefinition(id: "gate", name: "Gate", steps: [
            WorkflowStep(id: "check", type: .condition, condition: StepCondition(labelsAny: ["hotfix"]), routes: [
                "yes": WorkflowRoute(to: "fast"), "no": WorkflowRoute(to: "slow"),
            ]),
            WorkflowStep(id: "fast", type: .notify, message: "fast", next: "end"),
            WorkflowStep(id: "slow", type: .notify, message: "slow"),
        ])
        var script = DryRunScript(labels: ["hotfix"])
        #expect(try await DryRun.run(workflow, script: script).path == [WorkflowDefinition.triggerNodeID, "check", "fast", "end"])
        script.labels = []
        #expect(try await DryRun.run(workflow, script: script).path == [WorkflowDefinition.triggerNodeID, "check", "slow", "end"])
        workflow.steps[0].condition = StepCondition(diffLinesOver: 100)
        script.diff = DiffInfo(paths: ["a.swift"], lines: 500)
        #expect(try await DryRun.run(workflow, script: script).path.contains("fast"))
    }

    @Test func unroutedOutcomeFailsWithAnExplanation() async throws {
        let workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "review", type: .agent, role: "pr-reviewer", routes: ["approved": WorkflowRoute(to: "end")]),
        ])
        var script = DryRunScript()
        script.outcomes["review"] = ["rejected"]
        let report = try await DryRun.run(workflow, script: script)
        #expect(report.status == .failed)
        #expect(report.notes.first?.contains("has no route for “rejected”") == true)
    }

    @Test func driverStubsPlansSpawnsAndFinish() async throws {
        let workflow = try defaults("feature-delivery")
        let report = try await DryRun.run(workflow, script: .happyPath(for: workflow))
        let build = try #require(report.steps.first { $0.stepId == "build" })
        #expect(build.summary == "Dry run: 2 stubbed agents finished.")
        #expect(report.steps.last?.summary == "Dry run: would open a pull request.")
    }

    @Test func outcomeOptionsAndHappyDefaults() throws {
        let workflow = try defaults("feature-delivery")
        let review = try #require(workflow.step("review"))
        #expect(DryRunScript.options(for: review) == ["approved", "changes_requested"])
        #expect(DryRunScript.happyOutcome(for: review) == "approved")
        let qa = try #require(workflow.step("qa"))
        #expect(DryRunScript.happyOutcome(for: qa) == "passed")
        let plan = try #require(workflow.step("plan"))
        #expect(DryRunScript.options(for: plan) == ["done"])
        let gate = WorkflowStep(id: "g", type: .condition, condition: StepCondition())
        #expect(DryRunScript.options(for: gate).isEmpty)
        #expect(DryRunScript.happyOutcome(for: WorkflowStep(id: "a", type: .approval)) == "approved")
    }

    @Test func hotfixBuiltWithEditingHelpersRuns() async throws {
        var workflow = WorkflowDefinition.blank(id: "hotfix", name: "Hotfix")
        let dev = workflow.addStep(.agent, role: "claude-code", title: "Fix it")
        let qa = workflow.addStep(.agent, role: "qa-engineer", title: "Test it")
        let you = workflow.addStep(.approval, title: "You approve")
        workflow.connect(from: dev.id, to: qa.id)
        workflow.setRoute(from: qa.id, outcome: StepOutcome.passed, to: you.id)
        workflow.setRoute(from: qa.id, outcome: StepOutcome.failed, to: dev.id)
        workflow.setRoute(from: you.id, outcome: StepOutcome.approved, to: WorkflowDefinition.endStepID)
        workflow.setRoute(from: you.id, outcome: StepOutcome.changesRequested, to: dev.id)
        let config = ProjectConfig(roles: [RoleDefinition(id: "claude-code", name: "Claude Code"), RoleDefinition(id: "qa-engineer", name: "QA", editsCode: false)], workflows: [workflow])
        #expect(ConfigValidator.validate(config).isEmpty)
        #expect(workflow.step(qa.id)?.routes[StepOutcome.failed]?.maxLoops == 3)
        var script = DryRunScript.happyPath(for: workflow)
        script.outcomes[qa.id] = [StepOutcome.failed]
        let report = try await DryRun.run(workflow, script: script)
        #expect(report.status == .succeeded)
        #expect(report.steps.map(\.stepId) == ["claude-code", "qa-engineer", "claude-code", "qa-engineer", "approve", "end"])
    }
}

struct WorkflowVersionTests {
    private let base = WorkflowDefinition(id: "w", name: "W", version: 3, steps: [
        WorkflowStep(id: "build", type: .agent, role: "claude-code", instructions: "Build it"),
    ])

    @Test func unchangedWorkflowKeepsItsVersion() {
        #expect(base.preparedForSave(comparedTo: base).version == 3)
    }

    @Test func movingNodesDoesNotBumpTheVersion() {
        var moved = base
        moved.move("build", to: CanvasPosition(x: 10, y: 20))
        #expect(!moved.hasBehaviorChanges(comparedTo: base))
        let prepared = moved.preparedForSave(comparedTo: base)
        #expect(prepared.version == 3)
        #expect(prepared.step("build")?.position == CanvasPosition(x: 10, y: 20))
    }

    @Test func behaviorChangeBumpsTheVersionOnce() {
        var edited = base
        edited.steps[0].instructions = "Build it carefully"
        #expect(edited.preparedForSave(comparedTo: base).version == 4)
        edited.budget = 5
        #expect(edited.preparedForSave(comparedTo: base).version == 4)
    }

    @Test func newWorkflowKeepsItsVersion() {
        #expect(base.preparedForSave(comparedTo: nil).version == 3)
    }

    @Test func savingThroughTheLoaderWritesTheBumpedVersion() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "ensemble-version-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository) }
        try ProjectConfigLoader.installDefaults(repository: repository)
        let saved = try #require(ProjectConfigLoader.load(repository: repository).workflow("small-task"))
        var draft = saved
        draft.steps[0].instructions = "Fix the bug and add a regression test."
        draft.move("review", to: CanvasPosition(x: 400, y: 300))
        let written = try ProjectConfigLoader.save(draft, comparedTo: saved, repository: repository)
        #expect(written.version == saved.version + 1)
        let reloaded = try #require(ProjectConfigLoader.load(repository: repository).workflow("small-task"))
        #expect(reloaded == written)
        #expect(reloaded.step("review")?.position == CanvasPosition(x: 400, y: 300))
    }

    @Test func deleteRemovesTheFile() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "ensemble-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository) }
        try ProjectConfigLoader.installDefaults(repository: repository)
        try ProjectConfigLoader.deleteWorkflow("small-task", repository: repository)
        #expect(ProjectConfigLoader.load(repository: repository).workflow("small-task") == nil)
        #expect(throws: (any Error).self) { try ProjectConfigLoader.deleteWorkflow("small-task", repository: repository) }
    }
}

struct WorkflowLayoutTests {
    private let workflow = WorkflowDefinition(id: "w", name: "W", steps: [
        WorkflowStep(id: "check", type: .condition, condition: StepCondition(labelsAny: ["x"]), routes: [
            "yes": WorkflowRoute(to: "fast"), "no": WorkflowRoute(to: "slow"),
        ]),
        WorkflowStep(id: "fast", type: .agent, role: "a", next: "review"),
        WorkflowStep(id: "slow", type: .agent, role: "a"),
        WorkflowStep(id: "review", type: .agent, role: "b", routes: ["changes_requested": WorkflowRoute(to: "fast", maxLoops: 2), "approved": WorkflowRoute(to: "end")]),
    ])

    @Test func layoutIsDeterministic() {
        let first = WorkflowLayout.positions(for: workflow)
        for _ in 0..<5 {
            #expect(WorkflowLayout.positions(for: workflow) == first)
        }
    }

    @Test func layersFollowForwardEdgesAndIgnoreLoopBacks() {
        let depths = WorkflowLayout.depths(of: workflow)
        #expect(depths == ["check": 1, "fast": 2, "slow": 2, "review": 3])
        let positions = WorkflowLayout.positions(for: workflow)
        #expect(positions["check"] == CanvasPosition(x: 400, y: 180))
        #expect(positions["fast"] == CanvasPosition(x: 280, y: 300))
        #expect(positions["slow"] == CanvasPosition(x: 520, y: 300))
        #expect(positions["review"] == CanvasPosition(x: 400, y: 420))
        #expect(positions[WorkflowDefinition.triggerNodeID] == CanvasPosition(x: 400, y: 60))
        #expect(positions[WorkflowDefinition.endStepID] == CanvasPosition(x: 400, y: 540))
    }

    @Test func storedPositionsWin() {
        var moved = workflow
        moved.move("slow", to: CanvasPosition(x: 900, y: 900))
        let positions = WorkflowLayout.positions(for: moved)
        #expect(positions["slow"] == CanvasPosition(x: 900, y: 900))
        #expect(positions["fast"] == CanvasPosition(x: 280, y: 300))
        #expect(positions[WorkflowDefinition.endStepID]?.y == 1020)
    }

    @Test func emptyWorkflowPlacesTriggerAboveEnd() throws {
        let positions = WorkflowLayout.positions(for: .blank(id: "b", name: "B"))
        let trigger = try #require(positions[WorkflowDefinition.triggerNodeID])
        let end = try #require(positions[WorkflowDefinition.endStepID])
        #expect(trigger.y < end.y)
    }
}

struct WorkflowEditingTests {
    @Test func edgesIncludeStartImplicitAndLoopBacks() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "ensemble-edges-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository) }
        try ProjectConfigLoader.installDefaults(repository: repository)
        let workflow = try #require(ProjectConfigLoader.load(repository: repository).workflow("small-task"))
        let edges = workflow.edges
        #expect(edges.first == WorkflowEdge(from: WorkflowDefinition.triggerNodeID, to: "build", kind: .start))
        let loop = try #require(edges.first { $0.from == "review" && $0.outcome == "changes_requested" })
        #expect(loop.isLoopBack && loop.maxLoops == 2 && loop.to == "build")
        let forward = try #require(edges.first { $0.from == "review" && $0.outcome == "approved" })
        #expect(!forward.isLoopBack)
        #expect(edges.contains(WorkflowEdge(from: "approve", to: "end", kind: .route, outcome: "approved")))
    }

    @Test func implicitEdgeFollowsStepOrder() {
        let workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "a", type: .notify), WorkflowStep(id: "b", type: .notify),
        ])
        #expect(workflow.edges.contains(WorkflowEdge(from: "a", to: "b", kind: .implicit)))
        #expect(workflow.edges.contains(WorkflowEdge(from: "b", to: "end", kind: .implicit)))
    }

    @Test func addingAStepChainsItAfterTheLastStep() {
        var workflow = WorkflowDefinition(id: "w", name: "W", steps: [WorkflowStep(id: "a", type: .notify)])
        let added = workflow.addStep(.agent, role: "qa-engineer", position: CanvasPosition(x: 1, y: 2))
        #expect(workflow.step("a")?.next == "qa-engineer")
        #expect(added.id == "qa-engineer" && added.role == "qa-engineer" && added.next == "end")
        #expect(added.position == CanvasPosition(x: 1, y: 2))
        let second = workflow.addStep(.agent, role: "qa-engineer")
        let gate = workflow.addStep(.condition)
        let spawn = workflow.addStep(.spawn, role: "claude-code")
        let approval = workflow.addStep(.approval, role: "ignored")
        #expect(second.id == "qa-engineer-2")
        #expect(gate.condition == StepCondition())
        #expect(spawn.maxAgents == 4)
        #expect(approval.role == nil)
    }

    @Test func connectChoosesNextThenNamedOutcomes() {
        var workflow = WorkflowDefinition.blank(id: "w", name: "W")
        let a = workflow.addStep(.agent, role: "dev")
        let b = workflow.addStep(.agent, role: "qa")
        let gate = workflow.addStep(.condition)
        let first = workflow.connect(from: a.id, to: b.id)
        #expect(first == nil)
        #expect(workflow.step(a.id)?.next == b.id)
        let repeated = workflow.connect(from: a.id, to: b.id)
        #expect(repeated == nil)
        let second = workflow.connect(from: a.id, to: gate.id)
        #expect(second == "approved")
        let loop = workflow.connect(from: gate.id, to: a.id)
        #expect(loop == "yes")
        #expect(workflow.step(gate.id)?.routes["yes"] == WorkflowRoute(to: a.id, maxLoops: 3))
        let other = workflow.connect(from: gate.id, to: b.id)
        #expect(other == "no")
        #expect(workflow.step(gate.id)?.next == nil)
    }

    @Test func firstRouteReplacesThePlaceholderEnding() {
        var workflow = WorkflowDefinition.blank(id: "w", name: "W")
        let qa = workflow.addStep(.agent, role: "qa")
        #expect(workflow.step(qa.id)?.next == "end")
        workflow.setRoute(from: qa.id, outcome: StepOutcome.passed, to: WorkflowDefinition.endStepID)
        #expect(workflow.step(qa.id)?.next == nil)
        #expect(workflow.addStep(.approval).next == nil)
    }

    @Test func connectingFromTheTriggerMakesTheStepFirstWithoutChangingFlow() {
        var workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "a", type: .notify), WorkflowStep(id: "b", type: .notify),
        ])
        workflow.connect(from: WorkflowDefinition.triggerNodeID, to: "b")
        #expect(workflow.steps.map(\.id) == ["b", "a"])
        #expect(workflow.step("a")?.next == "b")
        #expect(workflow.step("b")?.next == "end")
    }

    @Test func removingAStepSplicesItsNextAndDropsRoutes() {
        var workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "a", type: .agent, role: "r", next: "b"),
            WorkflowStep(id: "b", type: .agent, role: "r", next: "c"),
            WorkflowStep(id: "c", type: .agent, role: "r", routes: ["failed": WorkflowRoute(to: "b"), "passed": WorkflowRoute(to: "end")]),
            WorkflowStep(id: "g", type: .condition, condition: StepCondition(outcomeOf: "b", equals: "done")),
        ])
        workflow.removeStep("b")
        #expect(workflow.step("a")?.next == "c")
        #expect(workflow.step("c")?.routes == ["passed": WorkflowRoute(to: "end")])
        #expect(workflow.step("g")?.condition?.outcomeOf == nil)
    }

    @Test func renamingAStepUpdatesEveryReference() {
        var workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "a", type: .agent, role: "r", next: "b"),
            WorkflowStep(id: "b", type: .agent, role: "r", routes: ["failed": WorkflowRoute(to: "b", maxLoops: 2)]),
            WorkflowStep(id: "g", type: .condition, condition: StepCondition(outcomeOf: "b")),
        ])
        let renamed = workflow.renameStep("b", to: "Code Review")
        #expect(renamed)
        #expect(workflow.steps.map(\.id) == ["a", "code-review", "g"])
        #expect(workflow.step("a")?.next == "code-review")
        #expect(workflow.step("code-review")?.routes["failed"] == WorkflowRoute(to: "code-review", maxLoops: 2))
        #expect(workflow.step("g")?.condition?.outcomeOf == "code-review")
        let collisions = [workflow.renameStep("a", to: "code-review"), workflow.renameStep("a", to: "end"), workflow.renameStep("a", to: "  ")]
        #expect(collisions == [false, false, false])
    }

    @Test func routesCanBeRenamedAndRemoved() {
        var workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "a", type: .agent, role: "r", routes: ["ok": WorkflowRoute(to: "end")]),
        ])
        let renamed = workflow.renameRoute(from: "a", outcome: "ok", to: "approved")
        #expect(renamed)
        #expect(workflow.step("a")?.routes.keys.sorted() == ["approved"])
        workflow.removeEdge(WorkflowEdge(from: "a", to: "end", kind: .route, outcome: "approved"))
        #expect(workflow.step("a")?.routes.isEmpty == true)
    }

    @Test func newIDsAreUniqueSlugs() {
        let existing = [WorkflowDefinition.blank(id: "hotfix", name: "Hotfix"), .blank(id: "hotfix-2", name: "Hotfix")]
        #expect(ProjectConfigLoader.newWorkflowID(for: "Hotfix", existing: existing) == "hotfix-3")
        #expect(ProjectConfigLoader.newWorkflowID(for: "Dependency upgrade", existing: existing) == "dependency-upgrade")
        #expect(ProjectConfigLoader.newWorkflowID(for: "!!!", existing: existing) == "workflow")
        let copy = existing[0].duplicated(id: "hotfix-copy", name: "Hotfix copy")
        #expect(copy.id == "hotfix-copy" && copy.version == 1 && copy.name == "Hotfix copy")
    }
}
