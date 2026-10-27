import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite struct ReviewPolicyTests {
    @Test func plansCarryAnOptionalSpec() throws {
        let arguments = JSONValue.parse(#"{"summary":"Refunds","tasks":[{"title":"API","role":"claude-code","files":["api/"]}],"spec":{"interfaces":["POST /refunds"],"acceptance_criteria":["Refunds never exceed the captured total"],"out_of_scope":["Partial refunds"],"verification":"Refund an order in the sandbox"}}"#)
        guard case .plan(let plan)? = try arguments.map(HandoffTool.submitPlan.decode) else {
            Issue.record("Expected a plan")
            return
        }
        let spec = try #require(plan.spec)
        #expect(spec.acceptanceCriteria == ["Refunds never exceed the captured total"])
        #expect(spec.markdown.contains("Out of scope:\n- Partial refunds"))
        #expect(RunEngine.describe(plan).contains("Verification: Refund an order in the sandbox"))

        let bare = JSONValue.parse(#"{"summary":"Typo","tasks":[{"title":"Fix typo","role":"claude-code"}],"spec":{}}"#)
        guard case .plan(let oneLiner)? = try bare.map(HandoffTool.submitPlan.decode) else {
            Issue.record("Expected a plan")
            return
        }
        #expect(oneLiner.spec == nil)
    }

    @Test func reviewerPinsCarryConfidenceAndCategory() throws {
        let arguments = JSONValue.parse(#"{"file":"a.py","start_line":3,"end_line":4,"title":"Race","explanation":"Two refunds","confidence":1.7,"category":"Correctness"}"#)
        guard case .pin(let draft)? = try arguments.map(HandoffTool.createPin.decode) else {
            Issue.record("Expected a pin")
            return
        }
        #expect(draft.confidence == 1)
        #expect(draft.category == "correctness")

        let reviewer = ReviewPolicy.Reviewer()
        #expect(reviewer.hides(confidence: 0.4, category: "correctness"))
        #expect(reviewer.hides(confidence: 0.9, category: "Style"))
        #expect(!reviewer.hides(confidence: 0.9, category: "security"))
        #expect(!reviewer.hides(confidence: nil, category: nil))
    }

    @Test func riskTiersComeFromPathsAndLabels() {
        let tiers = ReviewPolicy.RiskTiers()
        #expect(tiers.tier(of: "shop/payments/refunds.py") == .core)
        #expect(tiers.tier(of: "db/migrations/0042_refunds.py") == .core)
        #expect(tiers.tier(of: "docs/refunds.md") == .low)
        #expect(tiers.tier(of: "README.md") == .low)
        #expect(tiers.tier(of: "shop/orders/views.py") == .standard)
        #expect(tiers.tier(of: "shop/orders/views.py", labels: ["Security"]) == .core)
        #expect([RiskTier.low, .core, .standard].sorted() == [.core, .standard, .low])
    }

    @Test func reviewYAMLOverridesOnlyWhatItSets() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "review-yaml-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: ProjectConfig.directory(in: repository), withIntermediateDirectories: true)
        try "size_guard:\n  max_lines: 120\nreviewer:\n  min_confidence: 1.5\nrisk_tiers:\n  core: [\"billing/**\"]\n"
            .write(to: ReviewPolicy.file(in: repository), atomically: true, encoding: .utf8)
        let config = ProjectConfigLoader.load(repository: repository)
        #expect(config.review.sizeGuard.maxLines == 120)
        #expect(config.review.sizeGuard.maxFiles == 25)
        #expect(config.review.riskTiers.core == ["billing/**"])
        #expect(config.review.riskTiers.low == ReviewPolicy.RiskTiers.defaultLow)
        #expect(config.issues.map(\.message) == ["reviewer.min_confidence must be between 0 and 1"])
    }
}

@Suite struct GateScannerTests {
    @Test func findsSecretsInAddedLines() {
        let lines = [
            ScannedLine(file: "settings.py", line: 3, text: #"STRIPE = "sk_live_51HxQ8sDfLk2jE9aBcDeFgHiJk""#),
            ScannedLine(file: "deploy/key.pem", line: 1, text: "-----BEGIN RSA PRIVATE KEY-----"),
            ScannedLine(file: "config.py", line: 9, text: #"api_key = "4f9e2c1b7a6d5e3f8c0b""#),
            ScannedLine(file: "config.py", line: 10, text: #"api_key = os.environ["API_KEY"]"#),
            ScannedLine(file: "package-lock.json", line: 1, text: "AKIAABCDEFGHIJKLMNOP"),
        ]
        let findings = SecretScanner.scan(lines, agentName: "Dev 1")
        #expect(findings.map(\.title) == ["Possible secret: a Stripe live key", "Possible secret: a private key", "Possible secret: a hard-coded secret"])
        #expect(findings.allSatisfy { $0.severity == .blocking })
    }

    @Test func findsNewDependenciesInEachManifest() {
        let npm = DependencyScanner.newDependencies(
            file: "package.json",
            base: #"{"dependencies":{"react":"18"}}"#,
            head: #"{"dependencies":{"react":"18","left-padder":"1"},"devDependencies":{"vitest":"1"}}"#
        )
        #expect(npm.map(\.name) == ["left-padder", "vitest"])
        #expect(DependencyScanner.newDependencies(file: "requirements.txt", base: "django==5.1\n", head: "django==5.1\nhttpx>=0.27 # client\n").map(\.name) == ["httpx"])
        #expect(DependencyScanner.newDependencies(file: "Cargo.toml", base: nil, head: "[package]\nname = \"x\"\n[dependencies]\nserde = \"1\"\n").map(\.name) == ["serde"])
        #expect(DependencyScanner.newDependencies(file: "go.mod", base: "module x\n", head: "module x\nrequire (\n\tgithub.com/pkg/errors v0.9.1\n\tgolang.org/x/text v0.3.0 // indirect\n)\n").map(\.name) == ["github.com/pkg/errors"])
        #expect(DependencyScanner.newDependencies(file: "pyproject.toml", base: nil, head: "[project]\ndependencies = [\n  \"rich>=13\",\n  \"typer\",\n]\n").map(\.name) == ["rich", "typer"])
    }

    @Test func complexityGrowthIsMeasuredPerFile() {
        var diff = ScannedDiff()
        diff.added = (1...30).map { ScannedLine(file: "rules.py", line: $0, text: "    if a && b: return x") }
        diff.removed = (1...10).map { ScannedLine(file: "rules.py", line: $0, text: "    if a: return x") }
        let findings = ComplexityScanner.scan(diff, limit: 20, agentName: "Dev 1")
        #expect(findings.count == 1)
        #expect(findings.first?.title == "Complexity grew by 50 branches")
        #expect(ComplexityScanner.scan(diff, limit: 50, agentName: nil).isEmpty)
    }
}

@MainActor
@Suite(.serialized) struct AdvisoryReviewTests {
    typealias H = WorkflowHarness

    let workflow = WorkflowDefinition(id: "reviewed", name: "Reviewed", steps: [
        WorkflowStep(id: "build", type: .agent, role: "claude-code", next: "review"),
        WorkflowStep(id: "review", type: .agent, role: "pr-reviewer", routes: [
            StepOutcome.approved: WorkflowRoute(to: "approve"),
            StepOutcome.changesRequested: WorkflowRoute(to: "build", maxLoops: 3),
        ]),
        WorkflowStep(id: "approve", type: .approval, routes: [StepOutcome.approved: WorkflowRoute(to: "end")]),
    ])

    @Test func aReviewerGetsOneFixRoundThenTheWorkGoesToYouWithItsComments() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", H.done(), H.done())
        h.driver.script("review",
            H.verdict(StepOutcome.changesRequested, "Fix the cap", issues: [ReviewIssue(description: "Cap refunds at the captured total", file: "refunds.py", agent: "Dev 1")]),
            H.verdict(StepOutcome.changesRequested, "Still racy", issues: [ReviewIssue(description: "Lock the order row", file: "refunds.py")])
        )

        let id = try await h.start(workflow)

        #expect(try h.steps(id).map(\.stepId) == ["build", "review", "build", "review", "approve"])
        #expect(try h.hold(id)?.reason == .approval)
        let approval = try #require(try h.database.inboxItems(runId: id).last)
        #expect(approval.body.contains("Reviewer comments that weren’t addressed:\n• Lock the order row (refunds.py)"))
        #expect(!approval.body.contains("Cap refunds"))

        try h.engine.resolveApproval(try h.run(id), approved: true)
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.database.engineState(runId: id).reviewNotes.isEmpty)
    }

    @Test func fixRoundsComeFromReviewYAML() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        try ProjectConfigLoader.write(ReviewPolicy(reviewer: ReviewPolicy.Reviewer(fixRounds: 0)), repository: h.repository)
        h.driver.script("build", H.done())
        h.driver.script("review", H.verdict(StepOutcome.changesRequested, "Nit"))

        let id = try await h.start(workflow)
        #expect(try h.steps(id).map(\.stepId) == ["build", "review", "approve"])
        let approval = try #require(try h.database.inboxItems(runId: id).last)
        #expect(approval.body.hasSuffix("• Nit"))
    }
}

@MainActor
@Suite(.serialized) struct GateStepEngineTests {
    typealias H = WorkflowHarness

    let workflow = WorkflowDefinition(id: "gated", name: "Gated", steps: [
        WorkflowStep(id: "build", type: .agent, role: "claude-code", next: "gates"),
        WorkflowStep(id: "gates", type: .gates, routes: [StepOutcome.passed: WorkflowRoute(to: "end")]),
    ])

    static func gates(_ findings: [GateFinding]) -> ScriptedWorkflowDriver.Reply {
        let report = GateReport(findings: findings)
        return .result(StepResult(outcome: report.passed ? StepOutcome.passed : AgentWorkflowDriver.needsDecision, output: StepOutput(summary: report.summary, gates: report)))
    }

    static let dependency = GateFinding(kind: .dependency, severity: .blocking, title: "New dependency: left-padder", detail: "Approve it.", file: "package.json", agentName: "Dev 1")

    @Test func warningsAloneLetTheRunContinue() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", H.done())
        h.driver.script("gates", Self.gates([GateFinding(kind: .duplication, severity: .warning, title: "8 duplicated lines", detail: "Reuse it.")]))
        let id = try await h.start(workflow)
        #expect(try h.run(id).status == .succeeded)
    }

    @Test func blockingFindingsWaitForYouAndContinueOnApproval() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", H.done())
        h.driver.script("gates", Self.gates([Self.dependency]))

        let id = try await h.start(workflow)
        #expect(try h.hold(id)?.reason == .gates)
        let item = try #require(try h.database.inboxItems(runId: id).last)
        #expect(item.kind == .gate)
        #expect(item.body.contains("• Decide: New dependency: left-padder (Dev 1 · package.json)"))

        try h.engine.resolveGates(try h.run(id), proceed: true)
        await h.settle(id)
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.steps(id).last { $0.stepId == "gates" }?.outcome == StepOutcome.passed)
    }

    @Test func sendingBackGivesTheAuthorTheFindings() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", H.done(), H.done())
        h.driver.script("gates", Self.gates([Self.dependency]), Self.gates([]))

        let id = try await h.start(workflow)
        try h.engine.resolveGates(try h.run(id), proceed: false, note: "Don’t add a padding library")
        await h.settle(id)

        #expect(try h.run(id).status == .succeeded)
        #expect(try h.steps(id).map(\.stepId) == ["build", "gates", "build", "gates", "end"])
        let rebuild = try #require(h.driver.agentCalls.last { $0.step.id == "build" })
        #expect(rebuild.inputs.feedback?.summary == "Don’t add a padding library")
        #expect(rebuild.inputs.feedback?.issues.first?.description == "New dependency: left-padder. Approve it.")
    }
}

@MainActor
@Suite(.serialized) struct ReviewCapacityTests {
    typealias H = WorkflowHarness

    @Test func newRunsWaitToBuildWhileTooManyChangesWaitOnYou() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.engine.capacityPollInterval = .milliseconds(50)
        var settings = ProjectSettings()
        settings.reviewCapacity = 1
        try h.database.updateSettings(settings, forProject: try #require(h.project.id))
        let workflow = WorkflowDefinition(id: "w", name: "W", steps: [
            WorkflowStep(id: "build", type: .agent, role: "claude-code", next: "approve"),
            WorkflowStep(id: "approve", type: .approval, routes: [StepOutcome.approved: WorkflowRoute(to: "end")]),
        ])
        h.driver.script("build", H.done(), H.done())

        let first = try h.engine.start(task: try h.makeTask(), workflow: workflow, project: h.project)
        try await waitUntil { (try? h.database.engineState(runId: first.id!).hold?.reason) == .approval }
        let second = try h.engine.start(task: try h.makeTask(title: "Exports"), workflow: workflow, project: h.project)
        try await waitUntil { h.engine.waitingForCapacity.contains(second.id!) }
        #expect(h.driver.agentCalls.count == 1)

        try h.engine.resolveApproval(try h.run(first.id!), approved: true)
        try await waitUntil { (try? h.database.engineState(runId: second.id!).hold?.reason) == .approval }
        #expect(h.driver.agentCalls.count == 2)
        #expect(!h.engine.waitingForCapacity.contains(second.id!))
    }
}

struct StubRegistry: PackageRegistry {
    let known: Set<String>

    func exists(_ name: String, in ecosystem: PackageEcosystem) async -> Bool? {
        known.contains(name)
    }
}

@MainActor
@Suite(.serialized) struct GateRunnerTests {
    func makeBuilder() async throws -> (AgentHarness, AgentWorkflowDriver, AgentSession, Run, ProjectTask) {
        let harness = try await AgentHarness.make()
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.packageRegistry = StubRegistry(known: ["react", "left-pad"])
        let projectId = try #require(harness.project.id)
        let existing = (1...12).map { "    total = total + order.line_\($0).amount * order.line_\($0).quantity" }.joined(separator: "\n")
        try "def totals(order):\n    total = 0\n\(existing)\n    return total\n".write(to: harness.repo.root.appending(path: "totals.py"), atomically: true, encoding: .utf8)
        try #"{"dependencies":{"react":"18"}}"#.write(to: harness.repo.root.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try await harness.repo.git.run(["add", "-A"], in: harness.repo.root)
        try await harness.repo.git.run(["-c", "user.name=T", "-c", "user.email=t@x", "commit", "-qm", "Base"], in: harness.repo.root)
        let task = try harness.database.insert(ProjectTask(projectId: projectId, title: "Refund button", body: "", source: .chat, status: .running, labels: ["performance"], createdAt: .now, updatedAt: .now))
        let run = try harness.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "w", status: .running, startedAt: .now, title: "Refund button"), state: RunEngineState())
        let session = try await harness.runtime.createRunAgent(
            in: harness.project, role: RoleDefinition(id: "claude-code", name: "Claude Code"), runId: try #require(run.id), runStepId: nil, task: "Build it", git: harness.repo.git
        )
        return (harness, driver, session, run, task)
    }

    func context(run: Run, task: ProjectTask, project: Project) -> StepContext {
        StepContext(
            run: run, task: task, project: project, step: WorkflowStep(id: "gates", type: .gates), roleID: nil, iteration: 1, attempt: 1,
            runStepID: 1, start: .fresh, inputs: StepInputs(taskTitle: task.title, taskBody: "", labels: task.labels), stepBudgetUSD: nil, runBudgetRemainingUSD: nil
        )
    }

    @Test func scansTheBuildersDiffForEveryGate() async throws {
        let (harness, driver, session, run, task) = try await makeBuilder()
        defer { harness.cleanUp() }
        try ProjectConfigLoader.write(ReviewPolicy(sizeGuard: ReviewPolicy.SizeGuard(maxLines: 15, maxFiles: 10), gates: ReviewPolicy.Gates(maxDuplicateLines: 5)), repository: harness.repo.root)
        let worktree = try #require(session.agent.worktreeURL)
        let copied = (1...12).map { "    total = total + order.line_\($0).amount * order.line_\($0).quantity" }.joined(separator: "\n")
        try "def refund_totals(order):\n    total = 0\n\(copied)\n    return total\n".write(to: worktree.appending(path: "refunds.py"), atomically: true, encoding: .utf8)
        try #"{"dependencies":{"react":"18","left-padder":"1"}}"#.write(to: worktree.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "export const Button = () => null\nconst key = \"AKIAABCDEFGHIJKLMNOP\"\n".write(to: worktree.appending(path: "Button.tsx"), atomically: true, encoding: .utf8)
        try await harness.repo.git.run(["add", "-A"], in: worktree)
        try await harness.repo.git.run(["-c", "user.name=T", "-c", "user.email=t@x", "commit", "-qm", "Refunds"], in: worktree)

        let result = try await driver.runGateStep(context(run: run, task: task, project: harness.project))
        let report = try #require(result.output.gates)
        #expect(result.outcome == AgentWorkflowDriver.needsDecision)
        #expect(Set(report.blocking.map(\.kind)) == [.size, .secret, .dependency])
        #expect(report.blocking.first { $0.kind == .dependency }?.title == "Unknown package: left-padder")
        #expect(report.blocking.first { $0.kind == .secret }?.file == "Button.tsx")
        #expect(Set(report.warnings.map(\.kind)) == [.duplication, .evidence])
        #expect(report.warnings.filter { $0.kind == .evidence }.map(\.title) == ["UI change without a screenshot", "Performance work without a benchmark"])
    }

    @Test func attachedEvidenceClearsTheEvidenceWarnings() async throws {
        let (harness, driver, session, run, task) = try await makeBuilder()
        defer { harness.cleanUp() }
        let worktree = try #require(session.agent.worktreeURL)
        try "export const Button = () => null\n".write(to: worktree.appending(path: "Button.tsx"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: worktree.appending(path: "button.png"))
        try "before 120ms, after 40ms".write(to: worktree.appending(path: "bench.txt"), atomically: true, encoding: .utf8)
        try await harness.repo.git.run(["add", "Button.tsx"], in: worktree)
        try await harness.repo.git.run(["-c", "user.name=T", "-c", "user.email=t@x", "commit", "-qm", "Button"], in: worktree)

        let reply = try await driver.receive(.evidence(EvidenceDraft(kind: .screenshot, file: "button.png", title: "Refund button")), from: session.id)
        #expect(reply == "Attached “Refund button” for the user to see in Changes.")
        _ = try await driver.receive(.evidence(EvidenceDraft(kind: .benchmark, file: "bench.txt", title: "Refund latency")), from: session.id)
        await #expect(throws: HandoffError.self) {
            _ = try await driver.receive(.evidence(EvidenceDraft(kind: .log, file: "/etc/hosts", title: "Hosts")), from: session.id)
        }

        let stored = try harness.database.evidence(runId: try #require(run.id))
        #expect(stored.map(\.title) == ["Refund button", "Refund latency"])
        #expect(stored.allSatisfy { FileManager.default.fileExists(atPath: $0.file) && $0.file.hasPrefix(harness.runtime.paths.evidenceDirectory(runId: run.id!).path) })

        let result = try await driver.runGateStep(context(run: run, task: task, project: harness.project))
        #expect(result.outcome == StepOutcome.passed)
        #expect(result.output.gates?.findings.isEmpty == true)
    }
}

@MainActor
@Suite(.serialized) struct MissionPipelineTests {
    @Test func theDefaultFeatureDeliveryRunsThePipelineToYourApproval() async throws {
        let harness = try await AgentHarness.make(mode: "workflow")
        defer { harness.cleanUp() }
        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        try ProjectConfigLoader.write(ChecksConfig(checks: [CheckDefinition(name: "files", kind: .test, command: "ls *.txt")]), repository: harness.repo.root)
        try await harness.repo.git.run(["add", ".ensemble"], in: harness.repo.root)
        try await harness.repo.git.run(["-c", "user.name=T", "-c", "user.email=t@x", "commit", "-qm", "Config"], in: harness.repo.root)
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.pollInterval = .milliseconds(20)
        driver.packageRegistry = StubRegistry(known: [])
        let engine = RunEngine(database: harness.database, driver: driver)
        let config = ProjectConfigLoader.load(repository: harness.repo.root)
        let task = try harness.database.insert(ProjectTask(
            projectId: harness.project.id!, title: "Add alpha and beta", body: "Two files, please.", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now
        ))
        let run = try engine.start(task: task, workflow: try #require(config.workflow("feature-delivery")), project: harness.project)

        try await waitUntil(timeout: .seconds(30)) { engine.holds[run.id!]?.reason == .planApproval }
        let planStep = try harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try engine.approvePlan(run, plan: plan)
        try await waitUntil(timeout: .seconds(60)) { engine.holds[run.id!]?.reason == .approval }

        let steps = try harness.database.runSteps(runId: run.id!)
        #expect(steps.map(\.stepId) == ["plan", "build", "checks", "gates", "review", "approve"])
        let outputs = steps.map { $0.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) } }
        #expect(outputs[2]?.checks.count == 2)
        #expect(outputs[3]?.gates?.passed == true)
        #expect(steps[4].outcome == StepOutcome.approved)

        let lead = try #require(try harness.database.agents(inProject: harness.project.id!).first { $0.runId == run.id && $0.role == "tech-lead" })
        let transcript = try String(contentsOf: harness.runtime.paths.transcript(lead.id!), encoding: .utf8)
        #expect(transcript.contains("## How to plan"))
        #expect(transcript.contains("## How to review"))
    }
}
