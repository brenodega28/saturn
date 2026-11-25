import Foundation
import Testing
@testable import SaturnCore

@Suite struct SpecPlanSectionTests {
    let document = SpecDocument(
        title: "One-stop approval", status: .draft,
        workers: [
            SpecWorker(role: "builder", name: "Swift Dev 1", reason: "Builds it", skills: ["swift"], model: "opus"),
            SpecWorker(role: "checker", name: "QA 1", reason: "Tests it end to end", skills: ["qa-engineer"]),
        ],
        workflow: "delivery",
        acceptanceCriteria: [SpecCriterion(text: "It works")]
    )

    let workflow = WorkflowDefinition(id: "delivery", name: "Delivery", description: "Plan, build, review, approve.", steps: [
        WorkflowStep(id: "plan", type: .agent, title: "Plan the work", agent: .lead, next: "build"),
        WorkflowStep(id: "build", type: .spawn, title: "Build the plan", agent: .builder, next: "gates"),
        WorkflowStep(id: "gates", type: .gates, title: "Gates", routes: ["passed": WorkflowRoute(to: "review"), "changes_requested": WorkflowRoute(to: "build")]),
        WorkflowStep(id: "review", type: .agent, title: "AI review", agent: .lead, routes: ["approved": WorkflowRoute(to: "qa"), "changes_requested": WorkflowRoute(to: "build")]),
        WorkflowStep(id: "qa", type: .agent, title: "QA", agent: .checker, routes: ["passed": WorkflowRoute(to: "approve"), "failed": WorkflowRoute(to: "build")]),
        WorkflowStep(id: "approve", type: .approval, title: "You approve", routes: ["approved": WorkflowRoute(to: "end")]),
    ])

    @Test func showsTheWorkflowWorkersTotalAndRemainingApprovals() {
        let html = SpecPageRenderer().render(document, workflow: workflow)
        #expect(SpecPageRenderer.sectionID(SpecPageRenderer.planHeading) == "section-plan-approvals")
        #expect(html.contains("<section id=\"section-plan-approvals\""))
        #expect(html.contains("<strong>Delivery v1</strong> <code>delivery</code>"))
        for step in ["Plan the work", "Build the plan", "AI review", "QA", "You approve"] { #expect(html.contains("<li>\(step) <span")) }
        #expect(html.contains("<td>builder</td><td><strong>Swift Dev 1</strong></td><td>Builds it</td><td><code>swift</code></td><td>opus</td>"))
        #expect(html.contains("<td>checker</td><td><strong>QA 1</strong></td><td>Tests it end to end</td><td><code>qa-engineer</code></td><td></td>"))
        #expect(html.contains("<strong>3 agents total</strong> (the lead and 2 workers)"))
        #expect(!html.contains("{{"))

        let remaining = SpecPlanSection(document: document, workflow: workflow).remainingApprovals
        #expect(remaining.contains("You approve: you approve the finished work"))
        #expect(remaining.contains("Gates: you decide on blocking findings"))
        #expect(remaining.contains("AI review: may send the work back for changes"))
        #expect(remaining.contains("QA: may send the work back for changes"))
        #expect(!remaining.contains { $0.hasPrefix("Plan the work") })
        #expect(remaining.first?.hasPrefix("The plan: goes straight to build") == true)
        #expect(remaining.last == SpecPlanSection.permissionLine)
        #expect(html.contains(SpecPlanSection.permissionLine))
    }

    @Test func draftsGetTheApproveControlAndCommittedSpecsDoNot() {
        let html = SpecPageRenderer().render(document, workflow: workflow)
        #expect(html.contains("<button id=\"spec-approve\" type=\"button\""))
        #expect(html.contains("window.lavish.queuePrompt('approve',{element:this,selector:'#spec-approve'"))
        #expect(html.contains("window.lavish.sendQueuedPrompts()"))
        #expect(SpecPageRenderer.bundledTemplate.contains("#spec-approve {"))
        var approved = document
        approved.status = .inProgress
        #expect(!SpecPageRenderer().render(approved, workflow: workflow).contains("id=\"spec-approve\""))
    }

    @Test func anUnresolvedWorkflowStillShowsWorkersAndTheCount() {
        let html = SpecPageRenderer().render(document)
        #expect(html.contains("<code>delivery</code> isn’t in this project"))
        #expect(html.contains("<strong>Swift Dev 1</strong>"))
        #expect(html.contains("<strong>3 agents total</strong>"))
        #expect(html.contains(SpecPlanSection.permissionLine))
        #expect(html.contains("id=\"spec-approve\""))
    }

    @Test func workflowSkillsAndModelRoundTripAndOldSpecsStillParse() throws {
        let parsed = try SpecDocument(markdown: document.markdown)
        #expect(parsed.workflow == "delivery")
        #expect(parsed.workers == document.workers)
        #expect(parsed.extraFrontMatter.isEmpty)
        #expect(try SpecDocument(markdown: parsed.markdown) == parsed)

        let old = try SpecDocument(markdown: "---\ntitle: Old\nworkers:\n  - {role: builder, name: Dev}\n---\n## Summary\n\nHi\n")
        #expect(old.workflow == nil)
        #expect(old.workers == [SpecWorker(role: "builder", name: "Dev")])
        #expect(old.workers[0].skills.isEmpty && old.workers[0].model == nil)

        let request = try JSONDecoder().decode(SpecDraftRequest.self, from: Data(#"{"title":"T","summary":"S","acceptance_criteria":["a"],"workflow":" delivery ","workers":[{"role":"builder","name":"Dev","skills":["swift",""],"model":"opus"}]}"#.utf8))
        #expect(request.workflow == "delivery")
        #expect(request.workers == [SpecWorker(role: "builder", name: "Dev", skills: ["swift"], model: "opus")])
        let schema = HandoffTool.draftSpec.inputSchema
        guard case .object(let root) = schema, case .object(let properties)? = root["properties"] else { Issue.record("no schema"); return }
        #expect(properties["workflow"] != nil)
        guard case .object(let workers)? = properties["workers"], case .object(let items)? = workers["items"], case .object(let fields)? = items["properties"] else {
            Issue.record("no worker schema")
            return
        }
        #expect(fields["skills"] != nil && fields["model"] != nil)
    }
}

@Suite struct SpecApprovalRuleTests {
    let workers = [SpecWorker(role: "builder", name: "Dev 1"), SpecWorker(role: "checker", name: "QA 1")]

    func plan(_ count: Int) -> Plan {
        Plan(summary: "S", tasks: (0..<count).map { PlanTask(id: "t\($0)", title: "Task \($0)") })
    }

    @Test func aPlanWithinTheApprovedBuildersFits() {
        #expect(SpecApproval.excess(plan: plan(1), workers: workers) == nil)
        #expect(SpecApproval.excess(plan: plan(1), workers: workers + [SpecWorker(role: "builder", name: "Dev 2")]) == nil)
        #expect(SpecApproval.excess(plan: plan(0), workers: workers) == nil)
    }

    @Test func moreBuildersOrANewRoleIsNamed() {
        #expect(SpecApproval.excess(plan: plan(3), workers: workers) == "Exceeds the approved spec: 3 builders planned, 1 approved")
        #expect(SpecApproval.excess(plan: plan(1), workers: [SpecWorker(role: "checker", name: "QA")]) == "Exceeds the approved spec: new role: builder")
    }

    @Test func onlyApprovedOrRunningSpecsWithWorkersCover() {
        var document = SpecDocument(title: "T", status: .approved, workers: workers)
        #expect(SpecApproval.covers(document))
        document.status = .inProgress
        #expect(SpecApproval.covers(document))
        document.status = .draft
        #expect(!SpecApproval.covers(document))
        #expect(!SpecApproval.covers(SpecDocument(title: "T", status: .approved)))
    }
}

@Suite struct SpecApproveTargetTests {
    @Test func theApproveControlOrABareApproveNoteIsAnApproval() {
        #expect(SpecFeedback.isApproval(LavishPrompt(prompt: "approve", selector: "#spec-approve")))
        #expect(SpecFeedback.isApproval(LavishPrompt(prompt: "", selector: "section#section-plan-approvals > div > button#spec-approve")))
        #expect(SpecFeedback.isApproval(LavishPrompt(prompt: "  Approve \n", selector: "main")))
        #expect(!SpecFeedback.isApproval(LavishPrompt(prompt: "approve once criterion 2 is fixed", selector: "main")))
        let (approvals, notes) = SpecFeedback.split([LavishPrompt(prompt: "approve"), LavishPrompt(prompt: "Shorter", selector: "section#section-summary")])
        #expect(approvals.count == 1 && notes.map(\.prompt) == ["Shorter"])
        let target = SpecFeedback.target(of: LavishPrompt(prompt: "Why 3?", selector: "section#section-plan-approvals > p"), in: SpecDocument(title: "T"))
        #expect(target == .section("Plan & approvals"))
    }
}

@MainActor
final class ApprovalLog {
    var approved: [Int64] = []
    var delivered: [String] = []
}

@MainActor
@Suite(.serialized) struct SpecPageApproveTests {
    typealias Setup = WorkflowDriverTests.Setup

    func approvePoll(note: String? = nil) -> String {
        let extra = note.map { #",{"uid":"2","prompt":"\#($0)","selector":"section#section-summary > p","tag":"p","text":"Add two text files."}"# } ?? ""
        return ##"{"session":{"status":"feedback"},"prompts":[{"uid":"1","prompt":"approve","selector":"#spec-approve","tag":"button","text":"Approve & start"}\##(extra)]}"##
    }

    func drafted() async throws -> (Setup, LeadChat, SpecReviews, FakeLavish, Chat) {
        let (setup, chat, reviews, fake) = try await SpecReviewTests().make()
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { SpecReviewTests().messages(setup, task).contains { $0.kind == .lead } }
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        _ = try await setup.driver.receive(.draftSpec(SpecReviewTests().request), from: lead.id!)
        try await waitUntil { fake.commands("poll").count == 1 }
        return (setup, chat, reviews, fake, task)
    }

    @Test func anApprovePromptApprovesAndRepliesWithoutReachingTheLead() async throws {
        let (setup, _, reviews, fake, task) = try await drafted()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let log = ApprovalLog()
        reviews.approve = { log.approved.append($0) }
        reviews.deliver = { _, message in log.delivered.append(message) }

        fake.queuePoll(approvePoll(note: "Shorter please"))
        try await waitUntil { !fake.commands("reply").isEmpty }
        #expect(log.approved == [task.id!])
        #expect(fake.commands("reply").last?.last == "Approved, run started.")
        #expect(log.delivered.count == 1)
        #expect(log.delivered[0].contains("On Summary: Shorter please"))
        #expect(!log.delivered[0].contains("approve"))
    }

    @Test func aFailedApprovalRepliesWithTheReasonAndDeliversNothing() async throws {
        let (setup, _, reviews, fake, _) = try await drafted()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let log = ApprovalLog()
        reviews.approve = { _ in throw LeadChatError.runInProgress }
        reviews.deliver = { _, message in log.delivered.append(message) }

        fake.queuePoll(approvePoll())
        try await waitUntil { !fake.commands("reply").isEmpty }
        #expect(fake.commands("reply").last?.last == "Not started: " + (LeadChatError.runInProgress.errorDescription ?? ""))
        #expect(log.delivered.isEmpty)
        #expect(fake.commands("end").isEmpty)
    }

    @Test func approvingFromThePageStartsTheRunAndRepliesBeforeTheSessionEnds() async throws {
        let (setup, chat, reviews, fake, task) = try await drafted()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        reviews.approve = { taskId in _ = try await chat.approveSpec(taskId: taskId, in: setup.project) }

        fake.queuePoll(approvePoll())
        try await waitUntil { fake.commands("end").count == 1 }
        let commands = fake.invocations.compactMap { $0.arguments.dropFirst(2).first }
        let reply = try #require(commands.firstIndex(of: "reply"))
        #expect(reply < (commands.firstIndex(of: "end") ?? -1))
        #expect(fake.commands("reply").last?.last == "Approved, run started.")
        #expect(try setup.harness.database.runs(taskId: task.id!).contains(where: \.isActive))
        #expect(reviews.sessions[task.id!] == nil)

        let run = try #require(try setup.harness.database.runs(taskId: task.id!).first)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let hold = try #require(try setup.harness.database.chatRequests(runId: run.id!).first { $0.kind == .planApproval })
        #expect(hold.body.hasPrefix("Exceeds the approved spec: 2 builders planned, 1 approved"))
        try await setup.engine.cancel(run)
    }

    @Test func aRealRunFromAnApprovedSpecSkipsThePlanHoldWhenThePlanFits() async throws {
        let (setup, chat, reviews, _) = try await SpecReviewTests().make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { SpecReviewTests().messages(setup, task).contains { $0.kind == .lead } }
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        var request = SpecReviewTests().request
        request.workers = [SpecWorker(role: "builder", name: "Alpha"), SpecWorker(role: "builder", name: "Beta")]
        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)

        let run = try await chat.approveSpec(taskId: task.id!, in: setup.project)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.runSteps(runId: run.id!))?.contains { $0.stepId == "build" } == true }
        #expect(try setup.harness.database.chatRequests(runId: run.id!).allSatisfy { $0.kind != .planApproval })
        try await setup.engine.cancel(try #require(try setup.harness.database.run(id: run.id!)))
    }
}

@MainActor
@Suite(.serialized) struct SpecPlanHoldTests {
    typealias H = WorkflowHarness

    @Test func aPlanThatFitsTheApprovedSpecGoesStraightToBuild() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.engine.approvedWorkers = { _ in [SpecWorker(role: "builder", name: "Dev 1"), SpecWorker(role: "builder", name: "Dev 2"), SpecWorker(role: "checker", name: "QA")] }
        h.driver.script("plan", .result(.plan(H.plan)))
        h.driver.script("build", H.done("Built"))
        h.driver.script("review", H.verdict(StepOutcome.approved))
        h.driver.script("qa", H.verdict(StepOutcome.passed))

        let id = try await h.start(try h.workflow("feature-delivery"))
        #expect(h.driver.spawnCalls.first?.plan == H.plan)
        #expect(try h.hold(id)?.reason == .approval)
        #expect(try h.database.chatRequests(runId: id).map(\.kind) == [.approval])
        #expect(try h.steps(id).first { $0.stepId == "plan" }?.status == .succeeded)
    }

    @Test func aPlanThatExceedsTheApprovedSpecHoldsAndNamesTheExcess() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.engine.approvedWorkers = { _ in [SpecWorker(role: "builder", name: "Dev 1")] }
        h.driver.script("plan", .result(.plan(H.plan)))

        let id = try await h.start(try h.workflow("feature-delivery"))
        #expect(try h.hold(id)?.reason == .planApproval)
        let request = try #require(try h.database.chatRequests(runId: id).first)
        #expect(request.body.hasPrefix("Exceeds the approved spec: 2 builders planned, 1 approved"))
        #expect(h.driver.spawnCalls.isEmpty)
    }

    @Test func runsWithoutASpecFollowApprovePlans() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("plan", .result(.plan(H.plan)))
        let held = try await h.start(try h.workflow("feature-delivery"))
        #expect(try h.hold(held)?.reason == .planApproval)
        #expect(try h.database.chatRequests(runId: held).first?.body.hasPrefix("Exceeds") == false)
    }
}
