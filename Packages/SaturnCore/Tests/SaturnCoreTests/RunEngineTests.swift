import Foundation
import GRDB
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct RunEngineTests {
    typealias H = WorkflowHarness

    @Test func featureDeliveryRunsEndToEndWithOneReviewLoop() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan, costUSD: 0.5)))
        h.driver.script("build", H.done("Built v1", cost: 2), H.done("Fixed the refund rounding", cost: 1))
        h.driver.script("review",
            H.verdict(StepOutcome.changesRequested, "Rounding is wrong", issues: [ReviewIssue(description: "Use cents", file: "refunds.py", agent: "Dev 1")], cost: 0.25),
            H.verdict(StepOutcome.approved, "Looks good", cost: 0.25))
        h.driver.script("qa", H.verdict(StepOutcome.passed, "All green", cost: 0.5))

        let workflow = try h.workflow("feature-delivery")
        let id = try await h.start(workflow)

        #expect(try h.run(id).status == .waitingOnYou)
        #expect(try h.task(of: id).status == .waitingOnYou)
        #expect(try h.hold(id)?.reason == .planApproval)
        #expect(h.engine.waitingReason(runID: id)?.reason == .planApproval)
        #expect(h.engine.activeRuns(projectID: try #require(h.project.id)).map(\.id) == [id])
        #expect(try h.database.openChatRequests(projectId: try #require(h.project.id)).map(\.kind) == [.planApproval])

        try h.engine.approvePlan(try h.run(id), plan: H.plan)
        await h.settle(id)

        #expect(try h.hold(id)?.reason == .approval)
        #expect(try h.run(id).currentStep == "approve")
        try h.engine.resolveApproval(try h.run(id), approved: true, note: "Ship it")
        await h.settle(id)

        let run = try h.run(id)
        #expect(run.status == .succeeded)
        #expect(run.mergedAt != nil)
        #expect(run.baseBranch == "main")
        #expect(run.pushedAt == nil)
        #expect(h.driver.pushCalls.isEmpty)
        #expect(run.costUSD == 4.5)
        #expect(run.endedAt != nil)
        #expect(try h.task(of: id).status == .done)
        #expect(h.engine.activeRuns(projectID: try #require(h.project.id)).isEmpty)
        #expect(h.driver.finishCalls.map(\.action) == [.merge])

        let steps = try h.steps(id)
        #expect(steps.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve", "end"])
        #expect(steps.map(\.iteration) == [1, 1, 1, 2, 2, 1, 1, 1])
        #expect(steps.allSatisfy { $0.status == .succeeded })
        #expect(steps.map(\.outcome) == ["done", "done", "changes_requested", "done", "approved", "passed", "approved", "done"])
        #expect(steps.map(\.costUSD) == [0.5, 2, 0.25, 1, 0.25, 0.5, 0, 0])

        let secondBuild = try #require(h.driver.spawnCalls.last)
        #expect(secondBuild.iteration == 2)
        #expect(secondBuild.feedback?.fromStep == "review")
        #expect(secondBuild.feedback?.issues.first?.file == "refunds.py")
        #expect(secondBuild.maxAgents == 4)
        #expect(h.driver.spawnCalls.first?.feedback == nil)

        let qa = try #require(h.driver.agentCalls.last)
        #expect(qa.step.id == "qa")
        #expect(qa.kind == .checker)
        #expect(qa.inputs.plan == H.plan)
        #expect(qa.inputs.latestVerdict?.outcome == StepOutcome.approved)
        #expect(qa.inputs.feedback == nil)
        #expect(qa.inputs.previousOutputs.map(\.stepId) == ["plan", "build", "review", "build", "review"])

        let state = try h.database.engineState(runId: id)
        #expect(state.loopCounts["review->changes_requested"] == 1)
        #expect(try h.database.openChatRequests(projectId: try #require(h.project.id)).isEmpty)
    }

    @Test func planApprovalUsesTheEditedPlanAndRejectionReplans() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let edited = Plan(summary: "Only the API for now.", tasks: [PlanTask(id: "api", title: "Refund API (cents)")])
        h.driver.script("plan", .result(.plan(H.plan)), .result(.plan(H.plan)))
        h.driver.script("build", .hang)

        let id = try await h.start(try h.workflow("feature-delivery"))
        try h.engine.rejectPlan(try h.run(id), note: "Split the UI out")
        await h.settle(id)

        #expect(h.driver.agentCalls.map(\.iteration) == [1, 2])
        #expect(h.driver.agentCalls.last?.inputs.feedback == Feedback(fromStep: "plan", outcome: "rejected", summary: "Split the UI out"))
        #expect(try h.steps(id).map(\.status) == [.failed, .waitingOnYou])

        try h.engine.approvePlan(try h.run(id), plan: edited)
        try await waitUntil { h.driver.spawnCalls.count == 1 }

        let spawn = try #require(h.driver.spawnCalls.first)
        #expect(spawn.plan == edited)
        #expect(spawn.step.inputs.plan == edited)
        let planRow = try #require(try h.steps(id).last { $0.stepId == "plan" })
        #expect(planRow.status == .succeeded)
        #expect(planRow.output?.contains("Refund API (cents)") == true)
        let inbox = try h.database.chatRequests(runId: id)
        #expect(inbox.map(\.status) == [.answered, .answered])
        #expect(inbox.map(\.response) == ["Split the UI out", "approved"])
        try await h.engine.cancel(try h.run(id))
    }

    @Test func loopLimitAsksThenContinuesOnceMore() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "tight", name: "Tight", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, next: "review"),
            WorkflowStep(id: "review", type: .agent, agent: .checker, routes: [
                StepOutcome.passed: WorkflowRoute(to: "end"),
                StepOutcome.failed: WorkflowRoute(to: "build", maxLoops: 1),
            ]),
        ])
        h.driver.script("build", H.done(), H.done(), H.done())
        h.driver.script("review", H.verdict(StepOutcome.failed, "1"), H.verdict(StepOutcome.failed, "2"), H.verdict(StepOutcome.passed))

        let id = try await h.start(workflow)

        let hold = try #require(try h.hold(id))
        #expect(hold.reason == .loopLimit)
        #expect(hold.outcome == StepOutcome.failed)
        #expect(try h.run(id).status == .waitingOnYou)
        #expect(try h.database.chatRequests(runId: id).last?.kind == .loopLimit)
        #expect(h.driver.calledSteps.filter { $0 == "build" }.count == 2)

        try h.engine.resolveLoopLimit(try h.run(id), continueOnce: true)
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(try h.steps(id).filter { $0.stepId == "build" }.map(\.iteration) == [1, 2, 3])
        #expect(h.driver.agentCalls.last { $0.step.id == "build" }?.inputs.feedback?.summary == "2")
        let state = try h.database.engineState(runId: id)
        #expect(state.extraLoops["review->failed"] == 1)
        #expect(state.loopCounts["review->failed"] == 2)
    }

    @Test func aBuildThatCommitsNothingAsksBeforeTheWorkIsCheckedAgain() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "loose", name: "Loose", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, next: "review"),
            WorkflowStep(id: "review", type: .agent, agent: .checker, routes: [
                StepOutcome.approved: WorkflowRoute(to: "end"),
                StepOutcome.changesRequested: WorkflowRoute(to: "build", maxLoops: 5),
            ]),
        ])
        h.driver.script("build", H.done(heads: ["crew/dev-1": "a1"]), H.done(heads: ["crew/dev-1": "a1"]))
        h.driver.script("review", H.verdict(StepOutcome.changesRequested, "Fix it"), H.verdict(StepOutcome.approved))

        let id = try await h.start(workflow)

        let hold = try #require(try h.hold(id))
        #expect(hold.reason == .loopLimit)
        #expect(hold.stepId == "build")
        #expect(hold.message.contains("changed nothing"))
        #expect(h.driver.calledSteps == ["build", "review", "build"])
        #expect(try h.steps(id).last?.status == .succeeded)

        try h.engine.resolveLoopLimit(try h.run(id), continueOnce: true)
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(h.driver.calledSteps == ["build", "review", "build", "review"])
    }

    @Test func aBuildWithNewCommitsGoesStraightToReview() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "loose", name: "Loose", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, next: "review"),
            WorkflowStep(id: "review", type: .agent, agent: .checker, routes: [
                StepOutcome.approved: WorkflowRoute(to: "end"),
                StepOutcome.changesRequested: WorkflowRoute(to: "build", maxLoops: 5),
            ]),
        ])
        h.driver.script("build", H.done(heads: ["crew/dev-1": "a1"]), H.done(heads: ["crew/dev-1": "a2"]))
        h.driver.script("review", H.verdict(StepOutcome.changesRequested, "Fix it"), H.verdict(StepOutcome.approved))

        let id = try await h.start(workflow)
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(h.driver.calledSteps == ["build", "review", "build", "review"])
    }

    @Test func loopLimitCanFailTheRun() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "tight", name: "Tight", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, next: "review"),
            WorkflowStep(id: "review", type: .agent, agent: .checker, routes: [
                StepOutcome.changesRequested: WorkflowRoute(to: "build", maxLoops: 0),
            ]),
        ])
        h.driver.script("build", H.done())
        h.driver.script("review", H.verdict(StepOutcome.changesRequested))
        let id = try await h.start(workflow)

        try h.engine.resolveLoopLimit(try h.run(id), continueOnce: false)

        #expect(try h.run(id).status == .failed)
        #expect(try h.task(of: id).status == .failed)
        #expect(try h.hold(id) == nil)
        #expect(try h.database.chatRequests(runId: id).map(\.status) == [.answered])
    }

    @Test func expensiveRunsKeepGoingWithoutAsking() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "pricey", name: "Pricey", steps: [
            WorkflowStep(id: "one", type: .agent, agent: .builder),
            WorkflowStep(id: "two", type: .agent, agent: .builder),
        ])
        h.driver.script("one", H.done(cost: 150))
        h.driver.script("two", H.done(cost: 150))

        let id = try await h.start(workflow)
        await h.settle(id)

        #expect(try h.hold(id) == nil)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.run(id).costUSD == 300)
        #expect(h.driver.calledSteps == ["one", "two"])
    }

    @Test func approvalRejectionLoopsBackWithTheNote() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = try h.workflow("small-task")
        h.driver.script("build", H.done(), H.done())
        h.driver.script("review", H.verdict(StepOutcome.approved), H.verdict(StepOutcome.approved))

        let id = try await h.start(workflow)
        #expect(try h.hold(id)?.reason == .approval)
        #expect(try h.database.chatRequests(runId: id).last?.kind == .approval)

        try h.engine.resolveApproval(try h.run(id), approved: false, note: "Add a confirmation dialog")
        await h.settle(id)

        let rebuild = try #require(h.driver.agentCalls.last { $0.step.id == "build" })
        #expect(rebuild.iteration == 2)
        #expect(rebuild.inputs.feedback?.fromStep == "approve")
        #expect(rebuild.inputs.feedback?.summary == "Add a confirmation dialog")
        #expect(try h.hold(id)?.reason == .approval)

        try h.engine.resolveApproval(try h.run(id), approved: true)
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.steps(id).filter { $0.stepId == "approve" }.map(\.outcome) == [StepOutcome.changesRequested, StepOutcome.approved])
    }

    @Test func conditionStepsRouteOnLabelsPathsDiffSizeAndOutcomes() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "gated", name: "Gated", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder),
            WorkflowStep(id: "is-urgent", type: .condition, condition: StepCondition(labelsAny: ["Urgent"]), routes: [
                StepOutcome.yes: WorkflowRoute(to: "touches-migrations"), StepOutcome.no: WorkflowRoute(to: "end"),
            ]),
            WorkflowStep(id: "touches-migrations", type: .condition, condition: StepCondition(pathsAny: ["**/migrations/**", "*.sql"]), routes: [
                StepOutcome.yes: WorkflowRoute(to: "big"), StepOutcome.no: WorkflowRoute(to: "end"),
            ]),
            WorkflowStep(id: "big", type: .condition, condition: StepCondition(diffLinesOver: 100), routes: [
                StepOutcome.yes: WorkflowRoute(to: "built"), StepOutcome.no: WorkflowRoute(to: "end"),
            ]),
            WorkflowStep(id: "built", type: .condition, condition: StepCondition(outcomeOf: "build", equals: "done"), routes: [
                StepOutcome.yes: WorkflowRoute(to: "dba"), StepOutcome.no: WorkflowRoute(to: "end"),
            ]),
            WorkflowStep(id: "dba", type: .notify, message: "A DBA should look at this", next: "end"),
        ])
        h.driver.script("build", H.done(), H.done())
        h.driver.diff = DiffInfo(paths: ["app/db/migrations/0042_refunds.py", "README.md"], lines: 240)

        let urgent = try await h.start(workflow, labels: ["urgent"])
        #expect(try h.run(urgent).status == .succeeded)
        #expect(try h.steps(urgent).map(\.stepId) == ["build", "is-urgent", "touches-migrations", "big", "built", "dba", "end"])
        #expect(try h.steps(urgent).compactMap(\.outcome).dropLast() == ["done", "yes", "yes", "yes", "yes", "done"])
        #expect(h.driver.diffRequests == 3)
        #expect(try h.run(urgent).linesChanged == 240)

        let calm = try await h.start(workflow, labels: ["docs"])
        #expect(try h.steps(calm).map(\.stepId) == ["build", "is-urgent", "end"])
        #expect(try h.steps(calm).first { $0.stepId == "is-urgent" }?.outcome == StepOutcome.no)
    }

    @Test func pathGlobsAndConditionsEvaluate() {
        #expect(PathGlob("**/migrations/**").matches("app/db/migrations/0001.py"))
        #expect(PathGlob("**/migrations/**").matches("migrations/0001.py"))
        #expect(PathGlob("*.sql").matches("db/schema.sql"))
        #expect(!PathGlob("src/*.swift").matches("src/deep/file.swift"))
        #expect(PathGlob("src/**/*.swift").matches("src/deep/file.swift"))
        #expect(PathGlob("src/**/*.swift").matches("src/file.swift"))
        #expect(PathGlob("docs/").matches("docs/guide/intro.md"))
        #expect(PathGlob("file?.txt").matches("file1.txt"))
        #expect(!PathGlob("payments/*").matches("src/payments/x.py"))

        let facts = ConditionFacts(labels: ["Bug"], diff: DiffInfo(paths: ["a.py"], lines: 50), outcomes: ["qa": "failed"])
        #expect(StepCondition(labelsAny: ["bug"]).evaluate(facts))
        #expect(!StepCondition(labelsAny: ["bug"], diffLinesOver: 50).evaluate(facts))
        #expect(StepCondition(outcomeOf: "qa", equals: "failed").evaluate(facts))
        #expect(!StepCondition(outcomeOf: "review").evaluate(facts))
        #expect(!StepCondition().evaluate(facts))
    }

    @Test func notifyCreatesANoticeAndContinues() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "ping", name: "Ping", steps: [
            WorkflowStep(id: "tell", type: .notify, title: "Heads up", message: "Build starting"),
            WorkflowStep(id: "build", type: .agent, agent: .builder),
        ], end: WorkflowEnd(action: .leave))
        h.driver.script("build", H.done())

        let id = try await h.start(workflow)

        #expect(try h.run(id).status == .succeeded)
        let notices = try h.database.openChatRequests(projectId: try #require(h.project.id))
        #expect(notices.map(\.kind) == [.notice])
        #expect(notices.first?.title == "Heads up")
        #expect(notices.first?.body == "Build starting")
        #expect(h.driver.finishCalls.map(\.action) == [.leave])
        let notice = try #require(notices.first?.id)
        try h.database.resolveChatRequest(id: notice, status: .dismissed)
        #expect(try h.database.openChatRequests(projectId: try #require(h.project.id)).isEmpty)
    }

    @Test func failingStepRetriesOnceThenAsks() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "flaky", name: "Flaky", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, onFailure: .retry),
        ])
        h.driver.script("build", .failure("boom 1"), .failure("boom 2"), H.done())

        let id = try await h.start(workflow)

        #expect(h.driver.agentCalls.map(\.attempt) == [1, 2])
        let firstFailure = try #require(try h.steps(id).first?.id)
        #expect(h.driver.agentCalls.last?.start == .retry(previousRunStepID: firstFailure))
        let hold = try #require(try h.hold(id))
        #expect(hold.reason == .stepFailed)
        #expect(try h.run(id).lastError == "boom 2")
        #expect(try h.database.chatRequests(runId: id).last?.kind == .failure)

        try h.engine.resolveFailure(try h.run(id), retry: true)
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(try h.steps(id).map(\.status) == [.failed, .failed, .succeeded, .succeeded])
        #expect(try h.steps(id).map(\.iteration) == [1, 1, 1, 1])
    }

    @Test func retrySucceedsOnSecondAttempt() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "flaky", name: "Flaky", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, onFailure: .retry),
        ])
        h.driver.script("build", .failure("transient"), H.done())

        let id = try await h.start(workflow)

        #expect(try h.run(id).status == .succeeded)
        #expect(try h.run(id).lastError == nil)
        #expect(h.driver.agentCalls.map(\.attempt) == [1, 2])
    }

    @Test func failActionFailsTheRunAndRetryStepRevivesIt() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "strict", name: "Strict", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, onFailure: .fail),
        ])
        h.driver.script("build", .failure("compiler exploded"), H.done())

        let id = try await h.start(workflow)
        #expect(try h.run(id).status == .failed)
        #expect(try h.run(id).lastError == "compiler exploded")
        #expect(try h.task(of: id).status == .failed)
        #expect(try h.hold(id) == nil)

        try h.engine.retryStep(try h.run(id))
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.task(of: id).status == .done)
    }

    @Test func askActionCanFailTheRun() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "ask", name: "Ask", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder),
        ])
        h.driver.script("build", .failure("nope"))

        let id = try await h.start(workflow)
        #expect(h.driver.agentCalls.count == 1)
        #expect(try h.hold(id)?.reason == .stepFailed)

        try h.engine.resolveFailure(try h.run(id), retry: false)
        #expect(try h.run(id).status == .failed)
        #expect(try h.database.chatRequests(runId: id).map(\.response) == ["fail"])
    }

    @Test func timeoutPausesAndAsks() async throws {
        let h = try H.make(minute: .milliseconds(20))
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "slow", name: "Slow", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, timeoutMinutes: 1, onFailure: .fail),
        ])
        h.driver.script("build", .hang, H.done())

        let id = try await h.start(workflow)

        #expect(try h.hold(id)?.reason == .timedOut)
        #expect(try h.steps(id).first?.status == .failed)
        #expect(try h.run(id).lastError == "Step “build” ran longer than 1 minutes.")

        try h.engine.retryStep(try h.run(id))
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
    }

    @Test func recoveryResumesInterruptedStepsAndLeavesWaitingRunsWaiting() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)), .result(.plan(H.plan)))
        h.driver.script("build", .hang)

        let building = try await h.start(try h.workflow("feature-delivery"))
        try h.engine.approvePlan(try h.run(building), plan: H.plan)
        try await waitUntil { h.driver.spawnCalls.count == 1 }
        let waiting = try await h.start(try h.workflow("feature-delivery"))
        #expect(try h.run(building).status == .running)
        #expect(try h.run(waiting).status == .waitingOnYou)

        let driver = ScriptedWorkflowDriver()
        driver.script("build", H.done("Reattached and finished"))
        driver.script("review", .hang)
        let engine = RunEngine(database: h.database, driver: driver)
        try engine.recover()
        try await waitUntil { driver.agentCalls.count == 1 }

        let interrupted = try #require(try h.steps(building).first { $0.stepId == "build" })
        #expect(interrupted.status == .interrupted)
        let resumed = try #require(driver.spawnCalls.first)
        #expect(resumed.step.start == .resume(interruptedRunStepID: try #require(interrupted.id)))
        #expect(resumed.step.isResuming)
        #expect(resumed.iteration == 1)
        #expect(resumed.plan == H.plan)
        #expect(try h.steps(building).filter { $0.stepId == "build" }.map(\.status) == [.interrupted, .succeeded])
        #expect(driver.agentCalls.first?.step.id == "review")
        #expect(try h.run(waiting).status == .waitingOnYou)
        #expect(engine.waitingReason(runID: waiting)?.reason == .planApproval)
        #expect(Set(engine.activeRuns(projectID: try #require(h.project.id)).compactMap(\.id)) == [building, waiting])

        try engine.approvePlan(try h.run(waiting), plan: H.plan)
        try await waitUntil { try h.run(waiting).currentStep == "build" }
        try await engine.cancel(try h.run(building))
        try await engine.cancel(try h.run(waiting))
    }

    @Test func runsKeepTheWorkflowVersionTheyStartedWith() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        var workflow = try h.workflow("small-task")
        h.driver.script("build", .hang)
        let id = try await startWithoutWaiting(h, workflow)
        try await waitUntil { h.driver.agentCalls.count == 1 }

        workflow.version = 2
        workflow.steps = [WorkflowStep(id: "build", type: .agent, agent: .builder, next: "end")]
        workflow.end = WorkflowEnd(action: .merge)
        try ProjectConfigLoader.write(workflow, repository: h.repository)
        #expect(try h.workflow("small-task").steps.count == 1)

        let run = try h.run(id)
        #expect(run.workflowVersion == "1")
        #expect(run.endAction == "merge")
        let snapshot = try h.engine.workflow(for: run)
        #expect(snapshot.id == "small-task")
        #expect(snapshot.steps.map(\.id) == ["build", "review", "approve"])

        try await h.engine.pause(run)
        let fresh = RunEngine(database: h.database, driver: h.driver)
        h.driver.script("build", H.done())
        h.driver.script("review", H.verdict(StepOutcome.approved))
        try fresh.resume(try h.run(id))
        await fresh.waitUntilIdle(runID: id)

        #expect(try h.steps(id).map(\.stepId) == ["build", "build", "review", "approve"])
        #expect(try h.hold(id)?.reason == .approval)
    }

    @Test func pauseInterruptsAndResumeReattaches() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", .hang, H.done())
        let id = try await startWithoutWaiting(h, workflow)
        try await waitUntil { h.driver.agentCalls.count == 1 }

        try await h.engine.pause(try h.run(id))
        #expect(try h.run(id).status == .paused)
        #expect(try h.task(of: id).status == .waitingOnYou)
        #expect(try h.steps(id).map(\.status) == [.interrupted])
        #expect(!h.engine.isDriving(runID: id))

        try h.engine.resume(try h.run(id))
        await h.settle(id)
        #expect(h.driver.agentCalls.last?.start == .resume(interruptedRunStepID: try #require(try h.steps(id).first?.id)))
        #expect(try h.run(id).status == .succeeded)
    }

    @Test func cancelStopsTheRunAndTheDriver() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)))
        h.driver.script("build", .hang)
        let id = try await h.start(try h.workflow("feature-delivery"))
        try h.engine.approvePlan(try h.run(id), plan: H.plan)
        try await waitUntil { h.driver.spawnCalls.count == 1 }
        try h.database.createChatRequest(ChatRequest(projectId: try #require(h.project.id), runId: id, kind: .question, title: "Which currency?", createdAt: .now))

        try await h.engine.cancel(try h.run(id))

        let run = try h.run(id)
        #expect(run.status == .cancelled)
        #expect(run.endedAt != nil)
        #expect(try h.task(of: id).status == .incoming)
        #expect(h.driver.cancelledRuns == [id])
        #expect(try h.steps(id).map(\.status) == [.succeeded, .cancelled])
        #expect(try h.database.openChatRequests(projectId: try #require(h.project.id)).isEmpty)
        #expect(h.engine.activeRuns(projectID: try #require(h.project.id)).isEmpty)
        #expect(!h.engine.isDriving(runID: id))
        await #expect(throws: RunEngineError.self) { try await h.engine.cancel(try h.run(id)) }
    }

    @Test func unroutedOutcomeAsksInsteadOfShipping() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", H.done())
        h.driver.script("review", H.verdict("maybe"))
        let id = try await h.start(try h.workflow("small-task"))

        let hold = try #require(try h.hold(id))
        #expect(hold.reason == .stepFailed)
        #expect(hold.outcome == "maybe")
        #expect(h.driver.finishCalls.isEmpty)
    }

    @Test func finishFailureAsksAndRetries() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.failure(ScriptedFailure(message: "gh is not signed in")), .success(FinishResult(summary: "Merged", baseBranch: "main", mergedIntoBase: true))]

        let id = try await h.start(workflow)
        #expect(try h.hold(id)?.stepId == "end")
        #expect(try h.run(id).lastError == "gh is not signed in")

        try h.engine.retryStep(try h.run(id))
        await h.settle(id)
        #expect(try h.run(id).mergedAt != nil)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.steps(id).map(\.stepId) == ["build", "end", "end"])
    }

    @Test func aLeftInPlaceFinishRecordsTheDeliveryAndBaseBranches() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(deliveryBranch: "crew/delivery-run-1/refunds", baseBranch: "main"))]

        let id = try await h.start(workflow)

        let run = try h.run(id)
        #expect(run.status == .succeeded)
        #expect(run.deliveryBranch == "crew/delivery-run-1/refunds")
        #expect(run.baseBranch == "main")
        #expect(run.mergedAt == nil)
        #expect(h.driver.pushCalls.isEmpty)
    }

    @Test func pushingAMergedRunRecordsThePushOnce() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(summary: "Merged", baseBranch: "main", mergedIntoBase: true))]
        h.driver.pushReplies = [.success("Pushed main to origin · a41c9e2")]
        let id = try await h.start(workflow)

        let summary = try await h.engine.push(try h.run(id))

        let run = try h.run(id)
        #expect(summary == "Pushed main to origin · a41c9e2")
        #expect(h.driver.pushCalls == [id])
        #expect(run.pushedAt != nil)
        #expect(run.status == .succeeded)
        await #expect(throws: RunEngineError.self) { try await h.engine.push(try h.run(id)) }
        #expect(h.driver.pushCalls == [id])
    }

    @Test func aFailedPushLeavesTheRunUnchanged() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(summary: "Merged", baseBranch: "main", mergedIntoBase: true))]
        h.driver.pushReplies = [.failure(ScriptedFailure(message: "shop has no origin remote to push main to."))]
        let id = try await h.start(workflow)
        let before = try h.run(id)

        await #expect(throws: ScriptedFailure.self) { try await h.engine.push(before) }

        #expect(try h.run(id) == before)
    }

    @Test func onlyMergedRunsCanBePushed() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done(), H.done())
        h.driver.finishReplies = [
            .success(FinishResult(summary: "Left in place")),
            .success(FinishResult(deliveryBranch: "crew/delivery", baseBranch: "main")),
        ]
        let undelivered = try await h.start(workflow)
        let delivered = try await h.start(workflow)

        await #expect(throws: RunEngineError.self) { try await h.engine.push(try h.run(undelivered)) }
        await #expect(throws: RunEngineError.self) { try await h.engine.push(try h.run(delivered)) }
        #expect(h.driver.pushCalls.isEmpty)

        try await h.engine.mergeDelivery(try h.run(delivered), method: .squash)
        _ = try await h.engine.push(try h.run(delivered))
        #expect(h.driver.pushCalls == [delivered])
    }

    @Test func mergingADeliveredRunRecordsTheMergeOnce() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(deliveryBranch: "crew/delivery", baseBranch: "main"))]
        let id = try await h.start(workflow)

        try await h.engine.mergeDelivery(try h.run(id), method: .squash)

        let run = try h.run(id)
        #expect(h.driver.mergeCalls == [.squash])
        #expect(h.driver.pushCalls.isEmpty)
        #expect(run.pushedAt == nil)
        #expect(run.mergedAt != nil)
        #expect(run.outcome == "Merged crew/delivery into main.")
        #expect(run.status == .succeeded)
        await #expect(throws: RunEngineError.self) { try await h.engine.mergeDelivery(try h.run(id), method: .mergeCommit) }
        #expect(h.driver.mergeCalls == [.squash])
    }

    @Test func aFailedMergeLeavesTheRunUnchanged() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(deliveryBranch: "crew/delivery", baseBranch: "main"))]
        h.driver.mergeReplies = [.failure(ScriptedFailure(message: "main is dirty"))]
        let id = try await h.start(workflow)
        let before = try h.run(id)

        await #expect(throws: ScriptedFailure.self) { try await h.engine.mergeDelivery(before, method: .rebase) }

        #expect(try h.run(id) == before)
        #expect(h.driver.mergeCalls == [.rebase])
    }

    @Test func onlyFinishedDeliveredRunsCanBeMerged() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(summary: "Left in place"))]
        let id = try await h.start(workflow)

        await #expect(throws: RunEngineError.self) { try await h.engine.mergeDelivery(try h.run(id), method: .mergeCommit) }
        #expect(h.driver.mergeCalls.isEmpty)
    }

    @Test func resolvingTheWrongHoldThrows() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)))
        let id = try await h.start(try h.workflow("feature-delivery"))

        #expect(throws: RunEngineError.notWaiting(.approval)) { try h.engine.resolveApproval(try h.run(id), approved: true) }
        #expect(throws: RunEngineError.notWaiting(.loopLimit)) { try h.engine.resolveLoopLimit(try h.run(id), continueOnce: true) }
        #expect(throws: RunEngineError.self) { try h.engine.retryStep(try h.run(id)) }
    }

    private func startWithoutWaiting(_ h: H, _ workflow: WorkflowDefinition) async throws -> Int64 {
        let run = try h.engine.start(task: try h.makeTask(), workflow: workflow, project: h.project)
        return try #require(run.id)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static let tightLoop = WorkflowDefinition(id: "tight", name: "Tight", steps: [
        WorkflowStep(id: "build", type: .agent, agent: .builder, next: "qa"),
        WorkflowStep(id: "qa", type: .agent, agent: .checker, routes: [
            StepOutcome.passed: WorkflowRoute(to: "end"),
            StepOutcome.failed: WorkflowRoute(to: "build", maxLoops: 1),
        ]),
    ])

    static let oneBuild = WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])

    @Test func aQAFailurePastItsLoopLimitGoesToTheLeadWithoutACard() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("build", H.done(), H.done(), H.done())
        let issue = ReviewIssue(description: "Refund total is off by one cent", file: "refunds.py", agent: "Dev 1")
        h.driver.script("qa", H.verdict(StepOutcome.failed, "1"), H.verdict(StepOutcome.failed, "Totals still wrong", issues: [issue]), H.verdict(StepOutcome.passed))

        let id = try await lead.start(Self.tightLoop)

        let hold = try #require(try h.hold(id))
        #expect(hold.reason == .loopLimit && hold.handledBy == .lead)
        #expect(try h.run(id).status == .waitingOnYou)
        #expect(try h.database.chatRequests(runId: id).isEmpty)
        #expect(try h.database.engineState(runId: id).leadAttempts == ["qa": 1])
        let brief = try #require(lead.briefs.first?.brief)
        #expect(lead.briefs.count == 1)
        #expect(brief.contains("run \(id) “Refunds v2”") && brief.contains("stopped at “qa”") && brief.contains("loop limit"))
        #expect(brief.contains("Totals still wrong") && brief.contains("Refund total is off by one cent (Dev 1, refunds.py)"))
        #expect(brief.contains("mcp__saturn__resolve_run_hold") && brief.contains("`continue` or `fail`"))
        #expect(brief.contains("mcp__saturn__message_agent") && brief.contains("mcp__saturn__spawn_agent") && brief.contains("mcp__saturn__open_worktree"))
        #expect(brief.contains("mcp__saturn__ask_human"))

        try h.engine.resolveLeadHold(try h.run(id), action: .continue)
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(try h.database.engineState(runId: id).extraLoops["qa->failed"] == 1)
    }

    @Test func aFailedStepGoesToTheLeadAndItsRetryMatchesTheRetryButton() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("build", .failure("compiler exploded"), H.done())

        let id = try await lead.start(Self.oneBuild)

        let hold = try #require(try h.hold(id))
        #expect(hold.reason == .stepFailed && hold.handledBy == .lead)
        #expect(hold.body == "compiler exploded Retry the step, or fail the run.")
        #expect(try h.database.chatRequests(runId: id).isEmpty)
        #expect(lead.briefs.first?.brief.contains("compiler exploded") == true)
        #expect(lead.briefs.first?.brief.contains("`retry` or `fail`") == true)

        try h.engine.resolveLeadHold(try h.run(id), action: .retry)
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(h.driver.agentCalls.map(\.attempt) == [1, 2])
        #expect(h.driver.agentCalls.last?.start == .retry(previousRunStepID: try #require(hold.runStepId)))
    }

    @Test func aTimedOutStepGoesToTheLeadAndItsFailMatchesTheFailButton() async throws {
        let h = try H.make(minute: .milliseconds(20))
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        let slow = WorkflowDefinition(id: "slow", name: "Slow", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, timeoutMinutes: 1, onFailure: .fail),
        ])
        h.driver.script("build", .hang)

        let id = try await lead.start(slow)

        #expect(try h.hold(id)?.reason == .timedOut)
        #expect(try h.hold(id)?.handledBy == .lead)
        #expect(lead.briefs.first?.brief.contains("ran longer than 1 minutes") == true)
        #expect(throws: RunEngineError.self) { try h.engine.resolveLeadHold(try h.run(id), action: .continue) }

        try h.engine.resolveLeadHold(try h.run(id), action: .fail)

        #expect(try h.run(id).status == .failed)
        #expect(try h.run(id).lastError == "“build” timed out")
        #expect(try h.hold(id) == nil)
        #expect(throws: RunEngineError.self) { try h.engine.resolveLeadHold(try h.run(id), action: .fail) }
    }

    @Test func aLoopLimitFailFromTheLeadFailsTheRunLikeTheUser() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("build", H.done(), H.done())
        h.driver.script("qa", H.verdict(StepOutcome.failed, "1"), H.verdict(StepOutcome.failed, "2"))
        let id = try await lead.start(Self.tightLoop)
        #expect(throws: RunEngineError.self) { try h.engine.resolveLeadHold(try h.run(id), action: .retry) }

        try h.engine.resolveLeadHold(try h.run(id), action: .fail)

        #expect(try h.run(id).status == .failed)
        #expect(try h.run(id).lastError == "“qa” sent work back to “build” 1 times")
    }

    @Test func anEndStepMergeConflictTellsTheLeadTheBranchAndFiles() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let driver = FinishFailingDriver(base: h.driver, error: WorkflowDriverError.mergeConflict(branch: "crew/builder-1/refunds", files: ["refunds.py", "totals.py"]))
        let engine = RunEngine(database: h.database, driver: driver)
        let lead = LeadInbox(h, engine: engine)
        h.driver.script("build", H.done())

        let id = try await lead.start(Self.oneBuild)

        let hold = try #require(try h.hold(id))
        #expect(hold.stepId == WorkflowDefinition.endStepID && hold.reason == .stepFailed && hold.handledBy == .lead)
        #expect(try h.database.chatRequests(runId: id).isEmpty)
        let brief = try #require(lead.briefs.first?.brief)
        #expect(brief.contains("stopped at “Finish”"))
        #expect(brief.contains("Branch: crew/builder-1/refunds"))
        #expect(brief.contains("- refunds.py\n- totals.py"))
    }

    @Test func anUnsafeEndStepMergeGoesToTheLead() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let driver = FinishFailingDriver(base: h.driver, error: WorkflowDriverError.unsafeMerge("main has uncommitted changes."))
        let engine = RunEngine(database: h.database, driver: driver)
        let lead = LeadInbox(h, engine: engine)
        h.driver.script("build", H.done())

        let id = try await lead.start(Self.oneBuild)

        #expect(try h.hold(id)?.handledBy == .lead)
        #expect(lead.briefs.first?.brief.contains("## Unsafe merge") == true)
        #expect(lead.briefs.first?.brief.contains("main has uncommitted changes.") == true)
    }

    @Test func theThirdHoldOnAStepGoesStraightToTheUser() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("build", .failure("boom 1"), .failure("boom 2"), .failure("boom 3"))
        let id = try await lead.start(Self.oneBuild)

        for _ in 0..<2 {
            #expect(try h.hold(id)?.handledBy == .lead)
            try h.engine.resolveLeadHold(try h.run(id), action: .retry)
            await h.settle(id)
        }

        let hold = try #require(try h.hold(id))
        #expect(hold.handledBy == .user)
        #expect(lead.briefs.count == 2)
        let card = try #require(try h.database.chatRequests(runId: id).last)
        #expect(card.kind == .failure && card.title == "“build” failed" && card.id == hold.requestId)
        #expect(card.body.hasPrefix("boom 3 Retry the step, or fail the run."))
        #expect(card.body.contains("lead already tried to fix this step twice"))
        #expect(throws: RunEngineError.self) { try h.engine.resolveLeadHold(try h.run(id), action: .retry) }
    }

    @Test func escalatingPostsTheOriginalCardWithTheLeadsQuestion() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("build", .failure("tests need a database"), H.done())
        let id = try await lead.start(Self.oneBuild)

        try h.engine.escalateToUser(try h.run(id), note: "Can I start Postgres locally?")

        let hold = try #require(try h.hold(id))
        #expect(hold.handledBy == .user)
        let card = try #require(try h.database.chatRequests(runId: id).last)
        #expect(card.kind == .failure && card.title == "“build” failed" && card.id == hold.requestId)
        #expect(card.body == "tests need a database Retry the step, or fail the run.\n\nThe lead asks: Can I start Postgres locally?")
        #expect(throws: RunEngineError.self) { try h.engine.escalateToUser(try h.run(id), note: nil) }

        try h.engine.resolveFailure(try h.run(id), retry: true)
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.database.chatRequest(id: try #require(card.id))?.status == .answered)
    }

    @Test func aRunWithoutAChatLeadStillAsksTheUser() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        var briefs: [String] = []
        h.engine.leadShouldHandle = { _, _, brief in briefs.append(brief) }
        h.driver.script("build", .failure("nope"))

        let id = try await h.start(Self.oneBuild)

        #expect(try h.hold(id)?.handledBy == .user)
        #expect(try h.database.chatRequests(runId: id).map(\.kind) == [.failure])
        #expect(briefs.isEmpty)
    }

    @Test func approvalHoldsStayWithTheUserInALeadChat() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("plan", .result(.plan(H.plan)))
        let id = try await lead.start(try h.workflow("feature-delivery"))

        #expect(try h.hold(id)?.reason == .planApproval)
        #expect(try h.hold(id)?.handledBy == .user)
        #expect(try h.database.chatRequests(runId: id).map(\.kind) == [.planApproval])
        #expect(lead.briefs.isEmpty)
    }

    @Test func aFailedManualMergeStillThrowsAndTellsTheLead() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let lead = LeadInbox(h)
        h.driver.script("build", H.done())
        h.driver.finishReplies = [.success(FinishResult(deliveryBranch: "crew/delivery", baseBranch: "main"))]
        h.driver.mergeReplies = [.failure(ScriptedFailure(message: "CONFLICT (content): Merge conflict in refunds.py"))]
        let id = try await lead.start(Self.oneBuild)

        await #expect(throws: ScriptedFailure.self) { try await h.engine.mergeDelivery(try h.run(id), method: .squash) }

        #expect(lead.merges.map(\.error) == ["CONFLICT (content): Merge conflict in refunds.py"])
        #expect(lead.merges.first?.run.deliveryBranch == "crew/delivery")
        #expect(try h.run(id).mergedAt == nil)
    }

    @Test func holdsSavedBeforeLeadHandlingDecodeAsUserHolds() throws {
        let json = #"{"hold":{"reason":"step_failed","stepId":"build","message":"“build” failed"},"loopCounts":{}}"#
        let state = try JSONDecoder().decode(RunEngineState.self, from: Data(json.utf8))
        #expect(state.hold?.handledBy == .user)
        #expect(state.hold?.body == nil)
        #expect(state.leadAttempts.isEmpty)
    }
}

@MainActor
final class LeadInbox {
    let harness: WorkflowHarness
    let engine: RunEngine
    var briefs: [(run: Run, hold: RunHold, brief: String)] = []
    var merges: [(run: Run, error: String)] = []

    init(_ harness: WorkflowHarness, engine: RunEngine? = nil) {
        self.harness = harness
        self.engine = engine ?? harness.engine
        self.engine.leadShouldHandle = { [unowned self] run, hold, brief in briefs.append((run, hold, brief)) }
        self.engine.mergeFailed = { [unowned self] run, error in merges.append((run, error)) }
    }

    func start(_ workflow: WorkflowDefinition) async throws -> Int64 {
        let task = try harness.makeTask()
        _ = try harness.database.insert(Agent(
            projectId: task.projectId, role: AgentKind.lead.rawValue, name: "Lead", status: .idle, readOnly: true, taskId: task.id, createdAt: .now, updatedAt: .now
        ))
        let run = try engine.start(task: task, workflow: workflow, project: harness.project)
        let id = try #require(run.id)
        await engine.waitUntilIdle(runID: id)
        return id
    }
}

@MainActor
final class FinishFailingDriver: WorkflowDriver {
    let base: ScriptedWorkflowDriver
    let error: any Error

    init(base: ScriptedWorkflowDriver, error: any Error) {
        self.base = base
        self.error = error
    }

    func runAgentStep(_ context: StepContext) async throws -> StepResult { try await base.runAgentStep(context) }
    func runSpawnStep(_ context: SpawnContext) async throws -> StepResult { try await base.runSpawnStep(context) }
    func runCheckStep(_ context: StepContext) async throws -> StepResult { try await base.runCheckStep(context) }
    func runGateStep(_ context: StepContext) async throws -> StepResult { try await base.runGateStep(context) }
    func diffInfo(_ run: Run) async -> DiffInfo { await base.diffInfo(run) }
    func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult { throw error }
    func cancel(_ run: Run) async { await base.cancel(run) }
    func mergeDelivery(_ run: Run, method: MergeMethod) async throws -> String { try await base.mergeDelivery(run, method: method) }
    func pushBase(_ run: Run) async throws -> String { try await base.pushBase(run) }
}
