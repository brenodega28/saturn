import Foundation
import Testing
@testable import EnsembleCore

struct RunGraphLayoutTests {
    static let branching = WorkflowDefinition(id: "branching", name: "Branching", steps: [
        WorkflowStep(id: "triage", type: .condition, routes: ["yes": WorkflowRoute(to: "backend"), "no": WorkflowRoute(to: "frontend")]),
        WorkflowStep(id: "backend", type: .agent, role: "dev", next: "review"),
        WorkflowStep(id: "frontend", type: .agent, role: "dev", next: "review"),
        WorkflowStep(id: "review", type: .agent, role: "lead", routes: [
            "approved": WorkflowRoute(to: "end"),
            "changes_requested": WorkflowRoute(to: "triage", maxLoops: 2),
            "again": WorkflowRoute(to: "review"),
        ]),
    ])

    static func run(currentStep: String?, status: RunStatus) -> Run {
        Run(id: 1, projectId: 1, taskId: 1, workflow: "branching", currentStep: currentStep, status: status, startedAt: .now)
    }

    static func step(_ id: Int64, _ stepId: String, iteration: Int = 1, status: RunStepStatus = .succeeded, outcome: String? = nil) -> RunStep {
        RunStep(id: id, runId: 1, stepId: stepId, iteration: iteration, status: status, outcome: outcome, startedAt: Date(timeIntervalSince1970: Double(id)))
    }

    @Test func layersFollowTheLongestForwardPathAndEndSitsBelowEverything() {
        let layers = RunGraph.layers(of: Self.branching)
        #expect(layers == ["triage": 0, "backend": 1, "frontend": 1, "review": 2, "end": 3])

        let graph = RunGraph(workflow: Self.branching, run: Self.run(currentStep: "triage", status: .running), steps: [], hold: nil)
        #expect(graph.nodes.map(\.id) == ["triage", "backend", "frontend", "review", "end"])
        #expect(graph.nodes.map(\.column) == [0, 0, 1, 0, 0])
        #expect(graph.layerCount == 4)
        #expect(graph.columnCount == 2)
        #expect(graph.node("end")?.title == "Finish")
    }

    @Test func edgesComeFromNextAndRoutesAndLoopBacksAreClassified() {
        let graph = RunGraph(workflow: Self.branching, run: Self.run(currentStep: nil, status: .pending), steps: [], hold: nil)
        let byID = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0) })
        #expect(Set(graph.edges.map(\.id)) == [
            "triage|no|frontend", "triage|yes|backend", "backend|next|review", "frontend|next|review",
            "review|again|review", "review|approved|end", "review|changes_requested|triage",
        ])
        #expect(byID["review|changes_requested|triage"]?.isLoopBack == true)
        #expect(byID["review|changes_requested|triage"]?.maxLoops == 2)
        #expect(byID["review|changes_requested|triage"]?.label == "Changes requested")
        #expect(byID["review|again|review"]?.isLoopBack == true)
        #expect(byID["review|approved|end"]?.isLoopBack == false)
        #expect(byID["backend|next|review"]?.label == nil)
    }

    @Test func implicitEdgesLinkStepsWithoutNextOrRoutes() throws {
        let workflow = WorkflowDefinition(id: "linear", name: "Linear", steps: [
            WorkflowStep(id: "a", type: .agent), WorkflowStep(id: "b", type: .notify),
        ])
        let graph = RunGraph(workflow: workflow, run: Self.run(currentStep: "a", status: .running), steps: [], hold: nil)
        #expect(graph.edges.map(\.id) == ["a|next|b", "b|next|end"])
        #expect(graph.nodes.map(\.layer) == [0, 1, 2])
    }

    @Test func takenEdgesAndVisitsCountLoopsButNotRetries() {
        let steps = [
            Self.step(1, "triage", outcome: "yes"),
            Self.step(2, "backend", status: .failed),
            Self.step(3, "backend", outcome: "done"),
            Self.step(4, "review", outcome: "changes_requested"),
            Self.step(5, "triage", iteration: 2, outcome: "no"),
            Self.step(6, "frontend", outcome: "done"),
            Self.step(7, "review", iteration: 2, outcome: "again"),
            Self.step(8, "review", iteration: 3, status: .running),
        ]
        let graph = RunGraph(workflow: Self.branching, run: Self.run(currentStep: "review", status: .running), steps: steps, hold: nil)
        let taken = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0.timesTaken) })
        #expect(taken["triage|yes|backend"] == 1)
        #expect(taken["triage|no|frontend"] == 1)
        #expect(taken["backend|next|review"] == 1)
        #expect(taken["frontend|next|review"] == 1)
        #expect(taken["review|changes_requested|triage"] == 1)
        #expect(taken["review|again|review"] == 1)
        #expect(taken["review|approved|end"] == 0)
        #expect(graph.node("triage")?.visits == 2)
        #expect(graph.node("backend")?.visits == 1)
        #expect(graph.node("review")?.visits == 3)
        #expect(graph.node("end")?.visits == 0)
        #expect(graph.node("review")?.state == .running)
        #expect(graph.node("triage")?.state == .visited)
        #expect(graph.node("end")?.state == .upcoming)
        #expect(RunGraph.transitions(steps).count == 6)
    }

    @Test func liveNodeStateFollowsTheRunAndItsHold() {
        let current = "backend"
        func state(_ status: RunStatus, _ hold: RunHold? = nil) -> RunGraph.NodeState? {
            RunGraph(workflow: Self.branching, run: Self.run(currentStep: current, status: status), steps: [], hold: hold).node(current)?.state
        }
        #expect(state(.running) == .running)
        #expect(state(.waitingOnYou, RunHold(reason: .approval, stepId: current, message: "")) == .waiting)
        #expect(state(.waitingOnYou, RunHold(reason: .timedOut, stepId: current, message: "")) == .failed)
        #expect(state(.paused) == .paused)
        #expect(state(.interrupted) == .paused)
        #expect(state(.failed) == .failed)
        #expect(state(.cancelled) == .upcoming)
    }
}

struct RunHistoryGroupingTests {
    typealias S = RunGraphLayoutTests

    @Test func retriesOfTheSameIterationGroupIntoOneEntry() {
        let steps = [
            S.step(1, "triage", outcome: "yes"),
            S.step(2, "backend", status: .interrupted),
            S.step(3, "backend", status: .failed),
            S.step(4, "backend", outcome: "done"),
            S.step(5, "review", outcome: "changes_requested"),
            S.step(6, "triage", iteration: 2, status: .running),
        ]
        let groups = RunHistory.group(steps)
        #expect(groups.map { $0.compactMap(\.id) } == [[1], [2, 3, 4], [5], [6]])

        let history = RunHistory(workflow: S.branching, steps: steps)
        #expect(history.entries.map(\.id) == [1, 2, 5, 6])
        #expect(history.entries[1].attempts.map(\.number) == [1, 2, 3])
        #expect(history.entries[1].attempts.map(\.status) == [.interrupted, .failed, .succeeded])
        #expect(history.entries[1].status == .succeeded)
        #expect(history.entries[3].status == .running)
        #expect(history.entries[3].endedAt == nil)
    }

    @Test func hopsNameWhereEachStepWentAndNumberTheLoops() {
        let steps = [
            S.step(1, "triage", outcome: "yes"),
            S.step(2, "backend", outcome: "done"),
            S.step(3, "review", outcome: "changes_requested"),
            S.step(4, "triage", iteration: 2, outcome: "yes"),
            S.step(5, "backend", iteration: 2, outcome: "done"),
            S.step(6, "review", iteration: 2, outcome: "changes_requested"),
            S.step(7, "triage", iteration: 3, status: .failed),
        ]
        let history = RunHistory(workflow: S.branching, steps: steps)
        #expect(history.entries.map { $0.hop?.to } == ["backend", "review", "triage", "backend", "review", "triage", nil])
        #expect(history.entries[0].hop?.isLoopBack == false)
        #expect(history.entries[2].hop?.loopNumber == 1)
        #expect(history.entries[5].hop?.loopNumber == 2)
        #expect(history.entries[5].hop?.maxLoops == 2)
        #expect(history.entries[5].hop?.toTitle == "triage")
        #expect(history.loops.count == 2)
    }

    @Test func durationUsesTheFirstStartAndTheLastEnd() {
        var first = S.step(1, "backend", status: .failed)
        first.endedAt = Date(timeIntervalSince1970: 10)
        var second = S.step(2, "backend")
        second.startedAt = Date(timeIntervalSince1970: 20)
        second.endedAt = Date(timeIntervalSince1970: 61)
        second.costUSD = 0.25
        first.costUSD = 0.5
        let entry = RunHistory(workflow: S.branching, steps: [first, second]).entries[0]
        #expect(entry.duration(now: .now) == 60)
        #expect(entry.costUSD == 0.75)
    }
}

@MainActor @Suite(.serialized) struct RunDetailEngineTests {
    typealias H = WorkflowHarness

    @Test func aLoopingRunShowsVisitsLoopsHandoffsAndAgents() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan, costUSD: 0.5)))
        h.driver.script("build", H.done("Built v1", cost: 1), H.done("Fixed rounding", cost: 0.75))
        h.driver.script("review",
            H.verdict(StepOutcome.changesRequested, "Rounding is wrong", issues: [ReviewIssue(description: "Use cents", file: "refunds.py")]),
            H.verdict(StepOutcome.approved, "Looks good"))
        h.driver.script("qa", H.verdict(StepOutcome.passed, "All green"))
        let id = try await h.start(try h.workflow("feature-delivery"))
        try h.engine.approvePlan(try h.run(id), plan: H.plan)
        await h.settle(id)

        let run = try h.run(id)
        let workflow = try h.engine.workflow(for: run)
        let steps = try h.steps(id)
        let projectID = try #require(h.project.id)
        let buildStepIDs = steps.filter { $0.stepId == "build" }.compactMap(\.id)
        let dev = try h.database.insert(Agent(
            projectId: projectID, runId: id, role: "claude-code", name: "Dev 1", status: .idle,
            runStepId: buildStepIDs.first, createdAt: .now, updatedAt: .now
        ))
        _ = try h.database.insert(Agent(projectId: projectID, runId: id, role: "qa-engineer", name: "QA", status: .idle, createdAt: .now, updatedAt: .now))

        let graph = RunGraph(workflow: workflow, run: run, steps: steps, hold: try h.hold(id))
        #expect(graph.node("build")?.visits == 2)
        #expect(graph.node("review")?.visits == 2)
        #expect(graph.node("approve")?.state == .waiting)
        #expect(graph.node("qa")?.state == .visited)
        let taken = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0.timesTaken) })
        #expect(taken["review|changes_requested|build"] == 1)
        #expect(taken["review|approved|qa"] == 1)
        #expect(taken["build|next|review"] == 2)
        #expect(taken["plan|next|build"] == 1)

        let history = RunHistory(workflow: workflow, steps: steps, agents: try h.database.agents(inRun: id))
        #expect(history.entries.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve"])
        #expect(history.entries[0].handoff.plan == H.plan)
        #expect(history.entries[1].handoff.result == "Built v1")
        #expect(history.entries[1].agentIDs == [try #require(dev.id)])
        #expect(history.entries[2].handoff.verdict?.outcome == StepOutcome.changesRequested)
        #expect(history.entries[2].issues.first?.file == "refunds.py")
        #expect(history.entries[2].hop?.isLoopBack == true)
        #expect(history.entries[2].hop?.loopNumber == 1)
        #expect(history.entries[2].hop?.maxLoops == 3)
        #expect(history.entries[3].feedback?.summary == "Rounding is wrong")
        #expect(history.entries[3].iteration == 2)
        #expect(history.entries[4].hop?.toTitle == "Test end to end")
        #expect(history.entries[6].status == .waitingOnYou)
        #expect(history.loops.count == 1)
        #expect(history.entries.reduce(0) { $0 + $1.costUSD } == run.costUSD)
    }

    @Test func aRetriedFailedStepIsOneEntryWithTwoAttempts() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", .failure("Tests crashed"), H.done("Built it"))
        h.driver.script("review", .hang)
        let id = try await h.start(try h.workflow("small-task"))
        let failedGraph = RunGraph(workflow: try h.engine.workflow(for: try h.run(id)), run: try h.run(id), steps: try h.steps(id), hold: try h.hold(id))
        #expect(failedGraph.node("build")?.state == .failed)

        try h.engine.retryStep(try h.run(id))
        for _ in 0..<500 where try h.steps(id).last?.stepId != "review" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try h.run(id)
        let workflow = try h.engine.workflow(for: run)
        let history = RunHistory(workflow: workflow, steps: try h.steps(id))
        #expect(history.entries.map(\.stepId) == ["build", "review"])
        #expect(history.entries[0].attempts.map(\.status) == [.failed, .succeeded])
        #expect(history.entries[0].attempts.first?.summary == "Tests crashed")
        #expect(history.entries[0].hop?.to == "review")
        let graph = RunGraph(workflow: workflow, run: run, steps: try h.steps(id), hold: nil)
        #expect(graph.node("build")?.visits == 1)
        #expect(graph.node("review")?.state == .running)
        try await h.engine.cancel(run)
    }
}
