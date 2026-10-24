import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct ReviewStoreTests {
    typealias H = WorkflowHarness

    static func makeRun(_ h: H, workflow: WorkflowDefinition? = nil) throws -> Run {
        let task = try h.makeTask()
        let snapshot = try workflow.map(ProjectConfigLoader.encodeYAML) ?? ""
        return try h.database.insert(Run(
            projectId: try #require(h.project.id), taskId: try #require(task.id), workflow: workflow?.id ?? "feature-delivery",
            status: .running, startedAt: .now, title: task.title, workflowSnapshot: snapshot
        ), state: RunEngineState())
    }

    @Test func storesUpdatesAndCountsPins() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let run = try Self.makeRun(h)
        let other = try Self.makeRun(h)
        let runId = try #require(run.id)
        let otherId = try #require(other.id)
        let agent = try h.database.insert(Agent(projectId: try #require(h.project.id), runId: runId, role: "claude-code", name: "Dev 1", status: .idle, createdAt: .now, updatedAt: .now))

        let money = try h.database.createPin(
            PinDraft(file: "orders/views.py", startLine: 51, endLine: 49, title: "Money leaves here", tags: ["Payments"], explanation: "Inside the transaction."),
            runId: runId, agentId: agent.id
        )
        let copy = try h.database.createPin(PinDraft(file: "ui/Drawer.tsx", startLine: 27, endLine: 29, title: "Wording", explanation: "I wrote this."), runId: runId, agentId: agent.id)
        try h.database.createPin(PinDraft(file: "a.py", startLine: 1, endLine: 1, title: "Other", explanation: ""), runId: otherId, agentId: nil)

        #expect(money.startLine == 49 && money.endLine == 51)
        #expect(money.lineLabel == "49–51")
        #expect(try h.database.pins(runId: runId).map(\.title) == ["Money leaves here", "Wording"])
        #expect(try h.database.openPinCount(runId: runId) == 2)
        #expect(try h.database.openPinCounts(projectId: try #require(h.project.id)) == [runId: 2, otherId: 1])

        let requested = try h.database.updatePin(id: try #require(copy.id), status: .changeRequested, response: "Say “original card”.")
        #expect(requested?.status == .changeRequested)
        #expect(try h.database.pin(id: try #require(copy.id))?.response == "Say “original card”.")
        #expect(try h.database.openPinCount(runId: runId) == 1)

        let summary = Pin.changeRequestSummary(try h.database.pins(runId: runId), agentNames: [try #require(agent.id): "Dev 1"])
        #expect(summary == "Changes requested on 1 pin:\n- ui/Drawer.tsx:27–29 “Wording” (pinned by Dev 1): Say “original card”.")

        #expect(try h.database.approveOpenPins(runId: runId) == 1)
        #expect(try h.database.pins(runId: runId).map(\.status) == [.approved, .changeRequested])
        #expect(try h.database.openPinCount(runId: otherId) == 1)
        #expect(try h.database.updatePin(id: 9999, status: .approved) == nil)
        #expect(Pin.changeRequestSummary([]) == "")
    }

    @Test func agentPinsDefaultToTheNewSide() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let runId = try #require(try Self.makeRun(h).id)
        let pin = try h.database.createPin(PinDraft(file: "a.py", startLine: 3, endLine: 3, title: "New", explanation: ""), runId: runId, agentId: nil)
        let pinId = try #require(pin.id)
        let stored = try #require(try h.database.pin(id: pinId))
        #expect(stored.side == .new)
        #expect(stored.byUser == false)

        try h.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO pin (runId, file, startLine, endLine, title, explanation, status, createdAt, updatedAt)
                VALUES (?, 'b.py', 1, 1, 'Raw', '', 'open', ?, ?)
                """, arguments: [runId, Date.now, Date.now])
        }
        let raw = try #require(try h.database.pins(runId: runId).first { $0.title == "Raw" })
        #expect(raw.side == .new)
        #expect(raw.byUser == false)
        #expect(raw.sideLineLabel == "1")
    }

    @Test func storesEditsAndDeletesComments() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let runId = try #require(try Self.makeRun(h).id)
        let agent = try h.database.insert(Agent(projectId: try #require(h.project.id), runId: runId, role: "claude-code", name: "Dev 1", status: .idle, createdAt: .now, updatedAt: .now))

        let added = try h.database.createComment(runId: runId, branchAgentId: agent.id, file: "a.py", side: .new, startLine: 14, endLine: 12, text: "Use cents.")
        let removed = try h.database.createComment(runId: runId, branchAgentId: nil, file: "b.py", side: .old, startLine: 7, endLine: 7, text: "Keep this check.")

        let addedId = try #require(added.id)
        let removedId = try #require(removed.id)
        let stored = try #require(try h.database.pin(id: addedId))
        #expect(stored.startLine == 12 && stored.endLine == 14)
        #expect(stored.side == .new && stored.byUser)
        #expect(stored.agentId == agent.id)
        #expect(stored.status == .changeRequested)
        #expect(stored.explanation == "Use cents." && stored.response == "Use cents.")
        #expect(stored.sideLineLabel == "12–14")

        let old = try #require(try h.database.pin(id: removedId))
        #expect(old.side == .old && old.byUser && old.agentId == nil)
        #expect(old.lineLabel == "7")
        #expect(old.sideLineLabel == "7 (removed)")

        let edited = try h.database.updateComment(id: addedId, text: "Use integer cents.")
        #expect(edited?.response == "Use integer cents.")
        #expect(try h.database.pin(id: addedId)?.explanation == "Use integer cents.")
        #expect(try h.database.pin(id: addedId)?.status == .changeRequested)
        #expect(try h.database.updateComment(id: 9999, text: "x") == nil)

        #expect(try h.database.deletePin(id: removedId))
        #expect(try h.database.pin(id: removedId) == nil)
        #expect(try h.database.deletePin(id: 9999) == false)
        #expect(try h.database.pins(runId: runId).map(\.file) == ["a.py"])
    }

    @Test func agentPinListingLeavesOutUserComments() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let runId = try #require(try Self.makeRun(h).id)
        let agent = try h.database.insert(Agent(projectId: try #require(h.project.id), runId: runId, role: "claude-code", name: "Dev 1", status: .idle, createdAt: .now, updatedAt: .now))
        let agentId = try #require(agent.id)

        try h.database.createPin(PinDraft(file: "a.py", startLine: 3, endLine: 3, title: "Agent pin", explanation: ""), runId: runId, agentId: agentId)
        try h.database.createComment(runId: runId, branchAgentId: agentId, file: "a.py", side: .old, startLine: 1, endLine: 1, text: "Put this back.")

        #expect(try h.database.pins(agentId: agentId).map(\.title) == ["Agent pin"])
        #expect(try h.database.pins(runId: runId).count == 2)
    }

    @Test func summarisesUserComments() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let runId = try #require(try Self.makeRun(h).id)
        let agent = try h.database.insert(Agent(projectId: try #require(h.project.id), runId: runId, role: "claude-code", name: "Dev 1", status: .idle, createdAt: .now, updatedAt: .now))
        let names = [try #require(agent.id): "Dev 1"]

        let comment = try h.database.createComment(runId: runId, branchAgentId: agent.id, file: "a.py", side: .new, startLine: 3, endLine: 3, text: "Rename this.")
        #expect(Pin.changeRequestSummary([comment], agentNames: names) == "Changes requested on 1 comment:\n- Reviewer comment on a.py:3, on Dev 1’s branch: Rename this.")

        let removed = try h.database.createComment(runId: runId, branchAgentId: agent.id, file: "a.py", side: .old, startLine: 12, endLine: 14, text: "Put this back.")
        #expect(Pin.changeRequestSummary([removed], agentNames: names) == "Changes requested on 1 comment:\n- Reviewer comment on a.py:12–14 (removed lines), on Dev 1’s branch: Put this back.")

        try h.database.createComment(runId: runId, branchAgentId: nil, file: "c.py", side: .old, startLine: 1, endLine: 2, text: "Why?")
        let pin = try h.database.createPin(PinDraft(file: "b.py", startLine: 5, endLine: 6, title: "Money", explanation: ""), runId: runId, agentId: agent.id)
        try h.database.updatePin(id: try #require(pin.id), status: .changeRequested, response: "Round down.")

        let summary = Pin.changeRequestSummary(try h.database.pins(runId: runId), agentNames: names)
        #expect(summary == """
            Changes requested on 1 pin and 3 comments:
            - Reviewer comment on a.py:3, on Dev 1’s branch: Rename this.
            - Reviewer comment on a.py:12–14 (removed lines), on Dev 1’s branch: Put this back.
            - b.py:5–6 “Money” (pinned by Dev 1): Round down.
            - Reviewer comment on c.py:1–2 (removed lines): Why?
            """)
        #expect(Pin.changeRequestSummary([comment, comment], agentNames: names).hasPrefix("Changes requested on 2 comments:"))
    }

    @Test func streamsPinUpdates() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let runId = try #require(try Self.makeRun(h).id)
        var iterator = h.database.pinUpdates(runId: runId).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try h.database.createPin(PinDraft(file: "a.py", startLine: 3, endLine: 3, title: "New", explanation: ""), runId: runId, agentId: nil)
        #expect(try await iterator.next()?.map(\.title) == ["New"])
    }

    @Test func viewedStateFollowsTheDiffFingerprint() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let runId = try #require(try Self.makeRun(h).id)
        let entry = BranchFileDiff(branch: "b", agentId: nil, agentName: "Dev", agentRole: "claude-code",
                                   diff: FileDiff(oldPath: "a.py", newPath: "a.py", change: .modified, patch: "v1"))
        let path = ChangedPath(path: "a.py", diffs: [entry], isConflicted: false)

        try h.database.setViewed(true, runId: runId, path: "a.py", fingerprint: path.fingerprint)
        #expect(try h.database.viewedPaths(runId: runId, current: [path]) == ["a.py"])

        var edited = entry
        edited.diff.patch = "v2"
        #expect(try h.database.viewedPaths(runId: runId, current: [ChangedPath(path: "a.py", diffs: [edited], isConflicted: false)]).isEmpty)

        try h.database.setViewed(true, runId: runId, path: "a.py", fingerprint: path.fingerprint)
        try h.database.setViewed(false, runId: runId, path: "a.py", fingerprint: path.fingerprint)
        #expect(try h.database.viewedFingerprints(runId: runId).isEmpty)
    }

    @Test func derivesReviewersFromReviewSteps() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let workflow = try h.workflow("feature-delivery")
        let run = try Self.makeRun(h, workflow: workflow)
        let runId = try #require(run.id)
        let projectId = try #require(h.project.id)

        func step(_ id: String, _ iteration: Int, _ status: RunStepStatus, _ output: StepOutput? = nil) throws -> RunStep {
            let encoded = try output.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            return try h.database.insert(RunStep(runId: runId, stepId: id, iteration: iteration, status: status, output: encoded, startedAt: .now))
        }
        _ = try step("plan", 1, .succeeded, StepOutput(plan: H.plan))
        _ = try step("build", 1, .succeeded, StepOutput(summary: "Built"))
        _ = try step("review", 1, .succeeded, StepOutput(verdict: Verdict(outcome: StepOutcome.approved, summary: "ok")))
        let secondReview = try step("review", 2, .succeeded, StepOutput(verdict: Verdict(
            outcome: StepOutcome.changesRequested, summary: "Fix rounding",
            issues: [ReviewIssue(description: "Use cents", file: "views.py:42", agent: "Dev 1")]
        )))
        let qa = try step("qa", 1, .running)
        _ = try step("approve", 1, .succeeded, StepOutput(verdict: Verdict(outcome: StepOutcome.approved, summary: "Approved")))

        let lead = Agent(projectId: projectId, runId: runId, role: "tech-lead", name: "Tech Lead", status: .idle, runStepId: secondReview.id, readOnly: true, createdAt: .now, updatedAt: .now)
        let tester = Agent(projectId: projectId, runId: runId, role: "qa-engineer", name: "QA Engineer", status: .working, runStepId: qa.id, readOnly: true, createdAt: .now, updatedAt: .now)
        let reviews = RunReviews.derive(run: run, steps: try h.database.runSteps(runId: runId), agents: [lead, tester])

        let views = reviews.reviews(for: "orders/views.py")
        #expect(views.map(\.reviewer) == ["Tech Lead", "QA Engineer"])
        #expect(views.map(\.state) == [.changesRequested, .reviewing])
        #expect(views.first?.notes == ["Use cents"])
        #expect(views.first?.role == "tech-lead")

        let other = reviews.reviews(for: "orders/serializers.py")
        #expect(other.map(\.state) == [.approved, .reviewing])
        #expect(other.first?.notes.isEmpty == true)
    }

    @Test func pinDecisionsDriveTheApprovalStep() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)))
        h.driver.script("build", H.done("Built v1"), H.done("Reworded the warning"))
        h.driver.script("review", H.verdict(StepOutcome.approved, "Fine"), H.verdict(StepOutcome.approved, "Fine"))
        h.driver.script("qa", H.verdict(StepOutcome.passed, "Green"), H.verdict(StepOutcome.passed, "Green"))
        let id = try await h.start(try h.workflow("feature-delivery"))
        try h.engine.approvePlan(try h.run(id), plan: H.plan)
        await h.settle(id)
        #expect(h.engine.waitingReason(runID: id)?.reason == .approval)

        let wording = try h.database.createPin(PinDraft(file: "ui/Drawer.tsx", startLine: 27, endLine: 29, title: "Wording", explanation: ""), runId: id, agentId: nil)
        try h.database.createPin(PinDraft(file: "orders/views.py", startLine: 49, endLine: 51, title: "Money", explanation: ""), runId: id, agentId: nil)
        try h.database.updatePin(id: try #require(wording.id), status: .changeRequested, response: "Mention the original card.")
        let summary = Pin.changeRequestSummary(try h.database.pins(runId: id))
        try h.engine.resolveApproval(try h.run(id), approved: false, note: summary)
        await h.settle(id)

        #expect(h.driver.spawnCalls.last?.feedback?.summary == summary)
        #expect(h.driver.spawnCalls.last?.feedback?.fromStep == "approve")
        #expect(h.engine.waitingReason(runID: id)?.reason == .approval)

        try h.database.updatePin(id: try #require(wording.id), status: .approved)
        #expect(try h.database.approveOpenPins(runId: id) == 1)
        #expect(try h.database.openPinCount(runId: id) == 0)
        try h.engine.resolveApproval(try h.run(id), approved: true, note: nil)
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
    }

    @Test func matchesIssueFilesLoosely() {
        #expect(RunReviews.matches(issueFile: "views.py", path: "orders/views.py"))
        #expect(RunReviews.matches(issueFile: "./orders/views.py:10-12", path: "orders/views.py"))
        #expect(RunReviews.matches(issueFile: "repo/orders/views.py", path: "orders/views.py"))
        #expect(!RunReviews.matches(issueFile: "iews.py", path: "orders/views.py"))
        #expect(!RunReviews.matches(issueFile: "", path: "orders/views.py"))
    }
}
