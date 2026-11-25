import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct RunEngineOrphanTests {
    typealias H = WorkflowHarness

    static let pair = WorkflowDefinition(id: "pair", name: "Pair", steps: [
        WorkflowStep(id: "build", type: .agent, agent: .builder, next: "check"),
        WorkflowStep(id: "check", type: .agent, agent: .checker, next: "end"),
    ])

    static let solo = WorkflowDefinition(id: "solo", name: "Solo", steps: [
        WorkflowStep(id: "build", type: .agent, agent: .builder, next: "end"),
    ])

    struct Orphan {
        let runID: Int64
        let intruder: RunEngine
        let intruderGate: ReplyGate
    }

    private func makeOrphan(_ h: H) async throws -> Orphan {
        let gate = ReplyGate()
        h.driver.script("build", .gated(gate), H.done("Resumed and built"))
        h.driver.script("check", .hang)
        let run = try h.engine.start(task: try h.makeTask(), workflow: Self.pair, project: h.project)
        let runID = try #require(run.id)
        try await waitUntil { h.driver.agentCalls.count == 1 }

        let intruderGate = ReplyGate()
        let intruderDriver = ScriptedWorkflowDriver()
        intruderDriver.script("build", .gated(intruderGate))
        let intruder = RunEngine(database: h.database, driver: intruderDriver)
        try intruder.recover()
        try await waitUntil { intruderDriver.agentCalls.count == 1 }

        gate.open(.done("Finished in the first process", branchHeads: [:], costUSD: 0))
        await h.engine.waitUntilIdle(runID: runID)
        #expect(!h.engine.isDriving(runID: runID))
        #expect(try h.run(runID).status == .running)
        return Orphan(runID: runID, intruder: intruder, intruderGate: intruderGate)
    }

    private func notes(_ h: H, runID: Int64) throws -> [LeadMessage] {
        try h.database.leadMessages(taskId: try h.run(runID).taskId).filter { $0.kind == .note }
    }

    private func releaseIntruder(_ orphan: Orphan) async {
        orphan.intruderGate.open(.done("Intruder finished", branchHeads: [:], costUSD: 0))
        await orphan.intruder.waitUntilIdle(runID: orphan.runID)
    }

    @Test func orphanedRunIsRevivedOnTheSecondCheckAndReachesItsNextStep() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let orphan = try await makeOrphan(h)
        let id = orphan.runID

        #expect(try h.engine.reviveOrphanedRuns() == [])
        #expect(!h.engine.isDriving(runID: id))
        #expect(try notes(h, runID: id).isEmpty)

        #expect(try h.engine.reviveOrphanedRuns() == [id])
        try await waitUntil { h.driver.agentCalls.count == 3 }

        let builds = try h.steps(id).filter { $0.stepId == "build" }
        #expect(builds.map(\.status) == [.interrupted, .interrupted, .succeeded])
        let resumed = h.driver.agentCalls[1]
        #expect(resumed.step.id == "build")
        #expect(resumed.start == .resume(interruptedRunStepID: try #require(builds[1].id)))
        #expect(h.driver.agentCalls[2].step.id == "check")
        #expect(try h.run(id).currentStep == "check")
        #expect(try h.run(id).status == .running)

        let posted = try notes(h, runID: id)
        #expect(posted.count == 1)
        #expect(posted.first?.runId == id)
        #expect(posted.first?.text.hasPrefix("Run “Refunds v2” had stopped moving at “") == true)
        #expect(posted.first?.text.hasSuffix("”, so Saturn picked it up again.") == true)
        #expect(ChatNotification(message: try #require(posted.first)) == nil)

        #expect(try h.engine.reviveOrphanedRuns() == [])
        #expect(try h.engine.reviveOrphanedRuns() == [])
        #expect(try notes(h, runID: id).count == 1)

        await releaseIntruder(orphan)
        #expect(try h.steps(id).filter { $0.stepId == "build" }.map(\.status) == [.interrupted, .interrupted, .succeeded])
        try await h.engine.cancel(try h.run(id))
    }

    @Test func liveWaitingPausedAndFinishedRunsAreNeverRevived() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", H.done(), .hang, .hang)
        h.driver.script("plan", .result(.plan(H.plan)))

        let finished = try await h.start(Self.solo)
        #expect(try h.run(finished).status == .succeeded)

        let live = try h.engine.start(task: try h.makeTask(), workflow: Self.solo, project: h.project)
        let liveID = try #require(live.id)
        try await waitUntil { h.driver.agentCalls.count == 2 }

        let paused = try h.engine.start(task: try h.makeTask(), workflow: Self.solo, project: h.project)
        let pausedID = try #require(paused.id)
        try await waitUntil { h.driver.agentCalls.count == 3 }
        try await h.engine.pause(try h.run(pausedID))
        #expect(try h.run(pausedID).status == .paused)

        let waiting = try await h.start(try h.workflow("feature-delivery"))
        #expect(try h.run(waiting).status == .waitingOnYou)

        for _ in 0..<3 {
            #expect(try h.engine.reviveOrphanedRuns() == [])
        }
        for id in [finished, liveID, pausedID, waiting] {
            #expect(try notes(h, runID: id).isEmpty)
        }
        #expect(h.driver.agentCalls.count == 4)
        #expect(try h.run(pausedID).status == .paused)
        #expect(try h.run(waiting).status == .waitingOnYou)

        try await h.engine.cancel(try h.run(liveID))
        try await h.engine.cancel(try h.run(pausedID))
        try await h.engine.cancel(try h.run(waiting))
    }

    @Test func runningRunWithAHoldIsNotRevived() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)))
        let id = try await h.start(try h.workflow("feature-delivery"))
        let held = try #require(try h.database.run(id: id))
        var forced = held
        forced.status = .running
        let updated = forced
        try await h.database.writer.write { db in try updated.update(db) }
        #expect(try h.hold(id) != nil)

        #expect(try h.engine.reviveOrphanedRuns() == [])
        #expect(try h.engine.reviveOrphanedRuns() == [])
        #expect(try notes(h, runID: id).isEmpty)
        try await h.engine.cancel(try h.run(id))
    }

    @Test func watchdogRevivesOnceAndStops() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let orphan = try await makeOrphan(h)
        let id = orphan.runID

        h.engine.startOrphanWatchdog(interval: .milliseconds(20))
        #expect(h.engine.isWatchingForOrphans)
        try await waitUntil { h.driver.agentCalls.count == 3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try notes(h, runID: id).count == 1)
        #expect(h.engine.isDriving(runID: id))

        h.engine.stopOrphanWatchdog()
        #expect(!h.engine.isWatchingForOrphans)

        await releaseIntruder(orphan)
        try await h.engine.cancel(try h.run(id))
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
}
