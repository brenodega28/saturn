import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
final class SpecGateDriver: WorkflowDriver {
    let scripted = ScriptedWorkflowDriver()
    let real: AgentWorkflowDriver

    init(real: AgentWorkflowDriver) {
        self.real = real
    }

    func runAgentStep(_ context: StepContext) async throws -> StepResult { try await scripted.runAgentStep(context) }
    func runSpawnStep(_ context: SpawnContext) async throws -> StepResult { try await scripted.runSpawnStep(context) }
    func runCheckStep(_ context: StepContext) async throws -> StepResult { try await scripted.runCheckStep(context) }
    func runGateStep(_ context: StepContext) async throws -> StepResult { try await real.runGateStep(context) }
    func diffInfo(_ run: Run) async -> DiffInfo { await scripted.diffInfo(run) }
    func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult { try await scripted.finish(run, end: end) }
    func cancel(_ run: Run) async { await scripted.cancel(run) }
    func mergeDelivery(_ run: Run, method: MergeMethod) async throws -> String { try await scripted.mergeDelivery(run, method: method) }
    func pushBase(_ run: Run) async throws -> String { try await scripted.pushBase(run) }
}

@MainActor
@Suite(.serialized) struct SpecLifecycleTests {
    typealias Setup = WorkflowDriverTests.Setup

    let request = SpecDraftRequest(
        title: "Alpha and beta files", owner: "Sam", summary: "Add two text files.",
        interfaces: ["alpha.txt", "beta.txt"], outOfScope: ["A gamma file"],
        acceptanceCriteria: ["alpha.txt exists", "beta.txt exists"], verification: "ls the repository root"
    )

    func makeChat() async throws -> (Setup, LeadChat) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let chat = LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver)
        return (setup, chat)
    }

    func messages(_ setup: Setup, _ task: ProjectTask) -> [LeadMessage] {
        (try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []
    }

    func draftURL(_ setup: Setup, _ task: ProjectTask) -> URL {
        SpecStore(paths: setup.harness.runtime.paths).draftURL(projectId: setup.project.id!, taskId: task.id!)
    }

    func mainCheckoutStatus(_ setup: Setup) async throws -> String {
        try await setup.harness.repo.git.run(["status", "--porcelain"], in: setup.harness.repo.root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theRequestLeadDraftsAndReplacesTheSpecOutsideTheCheckout() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(setup.driver.tools(for: leadAgent).contains(.draftSpec))
        let launch = try #require(setup.harness.launches().last)
        #expect(launch.contains("mcp__ensemble__draft_spec"))

        let reply = try await setup.driver.receive(.draftSpec(request), from: leadAgent.id!)
        #expect(reply.contains("source of truth"))
        #expect(reply.contains("spec/alpha-and-beta-files.md"))
        let url = draftURL(setup, task)
        #expect(url.path.hasPrefix(setup.harness.data.path))
        let first = try SpecDocument(markdown: String(contentsOf: url, encoding: .utf8))
        #expect(first.title == "Alpha and beta files" && first.status == .draft && first.owner == "Sam")
        #expect(first.acceptanceCriteria.map(\.text) == ["alpha.txt exists", "beta.txt exists"])
        #expect(try await mainCheckoutStatus(setup).isEmpty)

        var revised = request
        revised.title = "Alpha, beta and gamma"
        revised.owner = nil
        revised.acceptanceCriteria.append("gamma.txt exists")
        _ = try await setup.driver.receive(.draftSpec(revised), from: leadAgent.id!)
        let second = try SpecDocument(markdown: String(contentsOf: url, encoding: .utf8))
        #expect(second.title == "Alpha, beta and gamma" && second.owner == "Sam" && second.created == first.created)
        #expect(second.acceptanceCriteria.count == 3)
        let drafts = SpecStore(paths: setup.harness.runtime.paths).drafts(projectId: setup.project.id!)
        #expect(drafts.map(\.url.lastPathComponent) == [url.lastPathComponent])
        #expect(drafts.map(\.taskId) == [task.id] && drafts.first?.document?.title == "Alpha, beta and gamma")

        var edited = second
        edited.acceptanceCriteria[2].text = "gamma.txt exists and says hello"
        try edited.markdown.write(to: url, atomically: true, encoding: .utf8)
        await #expect {
            try await setup.driver.receive(.draftSpec(revised), from: leadAgent.id!)
        } throws: { error in
            (error as? HandoffError)?.errorDescription?.contains("gamma.txt exists and says hello") == true
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == edited.markdown)

        revised.acceptanceCriteria[2] = "gamma.txt exists and says hello"
        _ = try await setup.driver.receive(.draftSpec(revised), from: leadAgent.id!)
        #expect(try SpecDocument(markdown: String(contentsOf: url, encoding: .utf8)).acceptanceCriteria.last?.text == "gamma.txt exists and says hello")

        edited = try SpecDocument(markdown: String(contentsOf: url, encoding: .utf8))
        edited.verification = "Open each file"
        try edited.markdown.write(to: url, atomically: true, encoding: .utf8)
        try await chat.send("CHAT what changed?", to: task, in: setup.project)
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }
        let transcript = try String(contentsOf: setup.harness.runtime.paths.transcript(leadAgent.id!), encoding: .utf8)
        #expect(transcript.contains("the user edited this request’s spec draft"))
        #expect(transcript.contains("Open each file"))
        _ = try await setup.driver.receive(.draftSpec(revised), from: leadAgent.id!)
        #expect(try await mainCheckoutStatus(setup).isEmpty)
    }

    @Test func startingTheProposalCommitsTheSpecOnTheRunBranchAndSeedsThePlan() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        _ = try await setup.driver.receive(.draftSpec(request), from: leadAgent.id!)

        let run = try chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let runID = try #require(run.id)
        let git = setup.harness.repo.git
        let root = setup.harness.repo.root

        let branch = RunSpecLink.branch(runId: runID)
        let committed = try await git.run(["show", "\(branch):spec/alpha-and-beta-files.md"], in: root)
        let document = try SpecDocument(markdown: committed)
        #expect(document.status == .inProgress)
        #expect(document.linkedRuns == [runID])
        #expect(document.acceptanceCriteria.map(\.text) == ["alpha.txt exists", "beta.txt exists"])
        #expect(try await git.run(["log", "-1", "--format=%s", branch], in: root).trimmingCharacters(in: .whitespacesAndNewlines) == "Add spec: Alpha and beta files")
        #expect(try await mainCheckoutStatus(setup).isEmpty)
        #expect(try SpecDocument(markdown: String(contentsOf: draftURL(setup, task), encoding: .utf8)).status == .inProgress)

        let planStep = try #require(try setup.harness.database.runSteps(runId: runID).first { $0.stepId == "plan" })
        let plan = try #require(planStep.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        #expect(plan.spec?.acceptanceCriteria == ["alpha.txt exists", "beta.txt exists"])
        #expect(plan.spec?.verification == "ls the repository root")
        let transcript = try String(contentsOf: setup.harness.runtime.paths.transcript(leadAgent.id!), encoding: .utf8)
        #expect(transcript.contains("The user’s spec"))

        let planner = Plan(summary: "x", tasks: plan.tasks, spec: PlanSpec(interfaces: ["gamma()"], acceptanceCriteria: ["Something else"], verification: "Other"))
        _ = try await setup.driver.receive(.plan(planner), from: leadAgent.id!)
        try await setup.engine.cancel(try #require(setup.engine.runs[runID]))
    }

    @Test func plansKeepTheSpecFilesCriteria() {
        let file = PlanSpec(interfaces: ["alpha.txt"], acceptanceCriteria: ["alpha.txt exists"], verification: "")
        let merged = file.authoritative(over: PlanSpec(interfaces: ["alpha.txt", "gamma()"], outOfScope: ["delta"], acceptanceCriteria: ["Something else"], verification: "make test"))
        #expect(merged.acceptanceCriteria == ["alpha.txt exists"])
        #expect(merged.interfaces == ["alpha.txt", "gamma()"])
        #expect(merged.outOfScope == ["delta"])
        #expect(merged.verification == "make test")
        #expect(file.authoritative(over: nil) == file)
    }

    @Test func aFailedCriterionBlocksAndNotVerifiedOnlyWarns() {
        let criteria = ["alpha.txt exists", "beta.txt exists", "gamma.txt exists"]
        let review = Verdict(outcome: "approved", summary: "", criteria: [
            CriterionResult(criterion: "1. alpha.txt exists", status: .fail, evidence: "ls shows no alpha.txt"),
            CriterionResult(criterion: "beta.txt exists", status: .notVerified, evidence: "Couldn't run ls"),
        ])
        let findings = SpecCriteria.findings(criteria: criteria, verdicts: [review])
        #expect(findings.map(\.kind) == [.criteria, .criteria, .criteria])
        #expect(findings.map(\.severity) == [.blocking, .warning, .warning])
        #expect(findings[0].title == "Criterion 1 failed: alpha.txt exists")
        #expect(findings[0].detail == "ls shows no alpha.txt")
        #expect(findings[2].title == "Criterion 3 has no result: gamma.txt exists")
        #expect(!GateReport(findings: findings).passed)

        let qa = Verdict(outcome: "passed", summary: "", criteria: [
            CriterionResult(criterion: "1", status: .pass, evidence: "alpha.txt:1"),
            CriterionResult(criterion: "#2", status: .pass, evidence: "beta.txt:1"),
            CriterionResult(criterion: "Gamma.txt exists!", status: .pass, evidence: "gamma.txt:1"),
        ])
        #expect(SpecCriteria.findings(criteria: criteria, verdicts: [review, qa]).isEmpty)
        #expect(SpecCriteria.findings(criteria: criteria, verdicts: [qa, review]).map(\.severity) == [.blocking, .warning])
        #expect(SpecCriteria.findings(criteria: criteria, verdicts: []).isEmpty)
        #expect(SpecCriteria.report(criteria: criteria, verdicts: [review]).map(\.status) == [.fail, .notVerified, .notVerified])
    }

    @Test func verdictsDecodeCriterionResultsLeniently() throws {
        let arguments = JSONValue.parse(#"{"outcome":"approved","summary":"ok","criteria":[{"criterion":"1. alpha","status":"Passed","evidence":"a.txt"},{"criterion":2,"status":"not verified"},{"status":"fail"},"junk"]}"#)
        guard case .verdict(let verdict)? = try arguments.map(HandoffTool.submitVerdict.decode) else {
            Issue.record("Expected a verdict")
            return
        }
        #expect(verdict.criteria == [
            CriterionResult(criterion: "1. alpha", status: .pass, evidence: "a.txt"),
            CriterionResult(criterion: "2", status: .notVerified),
        ])
        let bare = JSONValue.parse(#"{"outcome":"approved","summary":"ok","criteria":"oops"}"#)
        guard case .verdict(let plain)? = try bare.map(HandoffTool.submitVerdict.decode) else {
            Issue.record("Expected a verdict")
            return
        }
        #expect(plain.criteria.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(Verdict(outcome: "approved", summary: "ok")), as: UTF8.self)
        #expect(!encoded.contains("criteria"))
        let schema = HandoffTool.submitVerdict.inputSchema.compactJSON
        #expect(schema.contains("\"criteria\"") && schema.contains("not_verified"))
    }

    @Test func theGateStepTurnsCriteriaIntoFindingsForSpecRunsOnly() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        _ = try await setup.driver.receive(.draftSpec(request), from: leadAgent.id!)
        let run = try chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)

        func gate(_ run: Run, _ verdicts: [(String, Verdict)]) async throws -> StepResult {
            let outputs = verdicts.enumerated().map { PreviousOutput(stepId: $0.element.0, iteration: $0.offset + 1, outcome: $0.element.1.outcome, output: StepOutput(verdict: $0.element.1)) }
            let context = StepContext(
                run: run, task: task, project: setup.project, step: WorkflowStep(id: "gates", type: .gates), kind: nil, iteration: 1, attempt: 1,
                runStepID: 0, start: .fresh, inputs: StepInputs(taskTitle: run.title, taskBody: "", previousOutputs: outputs),
                stepBudgetUSD: nil, runBudgetRemainingUSD: nil
            )
            return try await setup.driver.runGateStep(context)
        }
        let failing = Verdict(outcome: "approved", summary: "", criteria: [
            CriterionResult(criterion: "alpha.txt exists", status: .fail, evidence: "missing"),
            CriterionResult(criterion: "beta.txt exists", status: .notVerified, evidence: "no shell"),
        ])
        let blocked = try await gate(run, [("review", failing)])
        #expect(blocked.outcome == AgentWorkflowDriver.needsDecision)
        #expect(blocked.output.gates?.blocking.map(\.title) == ["Criterion 1 failed: alpha.txt exists"])
        #expect(blocked.output.gates?.warnings.map(\.title) == ["Criterion 2 not verified: beta.txt exists"])
        #expect(blocked.output.gates?.criteria.map(\.status) == [.fail, .notVerified])

        let passing = Verdict(outcome: "passed", summary: "", criteria: [
            CriterionResult(criterion: "1", status: .pass, evidence: "alpha.txt:1"),
            CriterionResult(criterion: "2", status: .pass, evidence: "beta.txt:1"),
        ])
        let cleared = try await gate(run, [("review", failing), ("qa", passing)])
        #expect(cleared.outcome == StepOutcome.passed)
        #expect(cleared.output.gates?.criteria.map(\.status) == [.pass, .pass])

        var other = run
        other.id = 999_999
        let unrelated = try await gate(other, [("review", failing)])
        #expect(unrelated.outcome == StepOutcome.passed)
        #expect(unrelated.output.gates?.findings.isEmpty == true)
        #expect(unrelated.output.gates?.criteria.isEmpty == true)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func approvalTicksPassingCriteriaAndMarksTheSpecDone() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let leadAgent = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        _ = try await setup.driver.receive(.draftSpec(request), from: leadAgent.id!)
        let run = try chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        let runID = try #require(run.id)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let planStep = try #require(try setup.harness.database.runSteps(runId: runID).first { $0.stepId == "plan" })
        let plan = try #require(planStep.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let runAgents = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == runID }
        let reviewer = try #require(runAgents.first { $0.kind == .lead && $0.taskId == nil })
        let qa = try #require(runAgents.first { $0.kind == .checker })
        for agent in [reviewer, qa] {
            let transcript = try String(contentsOf: setup.harness.runtime.paths.transcript(agent.id!), encoding: .utf8)
            #expect(transcript.contains(#"## Acceptance criteria to check\n1. alpha.txt exists\n2. beta.txt exists"#), "\(agent.role)")
        }

        let verdicts = [
            Verdict(outcome: "changes_requested", summary: "", criteria: [CriterionResult(criterion: "1", status: .fail), CriterionResult(criterion: "2", status: .pass)]),
            Verdict(outcome: "passed", summary: "", criteria: [CriterionResult(criterion: "alpha.txt exists", status: .pass)]),
            Verdict(outcome: "passed", summary: "", criteria: [CriterionResult(criterion: "beta.txt exists", status: .notVerified)]),
        ]
        let encoder = JSONEncoder()
        try await setup.harness.database.writer.write { db in
            for (index, verdict) in verdicts.enumerated() {
                var step = RunStep(
                    runId: runID, stepId: index == 0 ? "review" : "qa", iteration: 10 + index, status: .succeeded, outcome: verdict.outcome,
                    output: String(decoding: try encoder.encode(StepOutput(verdict: verdict)), as: UTF8.self), startedAt: .now, endedAt: .now
                )
                try step.insert(db)
            }
        }

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: runID))??.status == .succeeded }

        let git = setup.harness.repo.git
        let root = setup.harness.repo.root
        let merged = try SpecDocument(markdown: try await git.run(["show", "main:spec/alpha-and-beta-files.md"], in: root))
        #expect(merged.status == .done)
        #expect(merged.linkedRuns == [runID])
        #expect(merged.acceptanceCriteria == [SpecCriterion(text: "alpha.txt exists", checked: true), SpecCriterion(text: "beta.txt exists", checked: false)])
        let subjects = try await git.run(["log", "--format=%s", "main"], in: root)
        #expect(subjects.contains("Update spec: Alpha and beta files"))
        #expect(subjects.contains("Add spec: Alpha and beta files"))
        #expect(try SpecDocument(markdown: String(contentsOf: draftURL(setup, task), encoding: .utf8)).status == .done)
        #expect(!(try await git.run(["branch", "--list", RunSpecLink.branch(runId: runID)], in: root)).contains("spec-run"))
    }

    @Test func thePostReviewGateOnlyRaisesFindingsNotDecidedAtAnEarlierGate() {
        let size = GateFinding(kind: .size, severity: .blocking, title: "Large change: 900 lines in 3 files", detail: "Split it.", agentName: "Dev 1")
        let secret = GateFinding(kind: .secret, severity: .blocking, title: "Possible secret: a Stripe live key", detail: "Remove it.", file: "a.py", line: 3, agentName: "Dev 1")
        let newSecret = GateFinding(kind: .secret, severity: .blocking, title: "Possible secret: a private key", detail: "Remove it.", file: "b.pem", line: 1, agentName: "Dev 1")
        let criterion = GateFinding(kind: .criteria, severity: .blocking, title: "Criterion 1 failed: alpha.txt exists", detail: "missing")
        let earlier = PreviousOutput(stepId: "gates", iteration: 1, outcome: StepOutcome.passed, output: StepOutput(gates: GateReport(findings: [size, secret, criterion])))

        #expect(GateReport.undecided([size, secret, newSecret, criterion], after: [earlier], stepId: "criteria") == [newSecret, criterion])
        #expect(GateReport.undecided([size, secret], after: [earlier], stepId: "gates") == [size, secret])
        #expect(GateReport.undecided([size], after: [], stepId: "criteria") == [size])
    }

    @Test func aReviewersFailedCriterionBlocksAtThePostReviewGateOnTheDefaultWorkflow() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        let root = setup.harness.repo.root
        try FileManager.default.removeItem(at: ProjectConfig.directory(in: root).appending(path: "workflows/feature-delivery.yaml"))
        try ProjectConfigLoader.installDefaults(repository: root)
        let workflow = try #require(ProjectConfigLoader.load(repository: root).workflow("feature-delivery"))
        #expect(workflow.steps.map(\.id) == ["plan", "build", "checks", "gates", "review", "criteria", "approve"])
        #expect(workflow.step("review")?.routes[StepOutcome.approved]?.to == "criteria")

        let driver = SpecGateDriver(real: setup.driver)
        let engine = RunEngine(database: setup.harness.database, driver: driver)
        driver.scripted.script("plan", .result(.plan(WorkflowHarness.plan)))
        driver.scripted.script("build", WorkflowHarness.done())
        driver.scripted.script("checks", WorkflowHarness.done())
        driver.scripted.script("review", .result(.verdict(Verdict(outcome: StepOutcome.approved, summary: "Looks fine", criteria: [
            CriterionResult(criterion: "1. alpha.txt exists", status: .fail, evidence: "ls shows no alpha.txt"),
            CriterionResult(criterion: "2. beta.txt exists", status: .pass, evidence: "beta.txt:1"),
        ]))))

        let task = try setup.harness.database.insert(ProjectTask(
            projectId: setup.project.id!, title: "Alpha and beta", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now
        ))
        let run = try engine.start(task: task, workflow: workflow, project: setup.project)
        let runID = try #require(run.id)
        let store = SpecStore(paths: setup.harness.runtime.paths)
        let spec = SpecDocument(title: "Alpha and beta", status: .inProgress, linkedRuns: [runID], acceptanceCriteria: [SpecCriterion(text: "alpha.txt exists"), SpecCriterion(text: "beta.txt exists")])
        try store.write(spec, to: store.draftURL(projectId: setup.project.id!, taskId: task.id!))
        try store.save(RunSpecLink(projectId: setup.project.id!, taskId: task.id!, path: "spec/alpha-and-beta.md", branch: RunSpecLink.branch(runId: runID)), runId: runID)

        try await waitUntil(timeout: .seconds(30)) { engine.holds[runID]?.reason == .planApproval }
        try engine.approvePlan(run, plan: WorkflowHarness.plan)
        try await waitUntil(timeout: .seconds(30)) { engine.holds[runID]?.reason == .gates }

        let hold = try #require(engine.holds[runID])
        #expect(hold.stepId == "criteria")
        let steps = try setup.harness.database.runSteps(runId: runID)
        #expect(steps.map(\.stepId) == ["plan", "build", "checks", "gates", "review", "criteria"])
        #expect(steps.first { $0.stepId == "gates" }?.outcome == StepOutcome.passed)
        let item = try #require(try setup.harness.database.chatRequests(runId: runID).last)
        #expect(item.body.contains("Decide: Criterion 1 failed: alpha.txt exists"))
        #expect(!item.body.contains("beta.txt exists"))

        try engine.resolveGates(try #require(try setup.harness.database.run(id: runID)), proceed: true, note: "Accept it for now")
        try await waitUntil(timeout: .seconds(30)) { engine.holds[runID]?.reason == .approval }
        let decided = try #require(try setup.harness.database.runSteps(runId: runID).last { $0.stepId == "criteria" })
        #expect(decided.outcome == StepOutcome.passed)
        #expect(decided.output?.contains("You continued past them.") == true)
        #expect(try setup.harness.database.chatRequests(runId: runID).first { $0.id == item.id }?.response == "Accept it for now")
        try await engine.cancel(try #require(engine.runs[runID]))
    }

    @Test func requestsWithoutASpecStartExactlyAsBefore() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let run = try chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        #expect(SpecStore(paths: setup.harness.runtime.paths).link(runId: run.id!) == nil)
        #expect(try await setup.harness.repo.git.run(["branch", "--list", "ensemble/*"], in: setup.harness.repo.root).isEmpty)
        let plan = try #require(try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }?.output
            .flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        #expect(plan.spec == nil)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }
}
