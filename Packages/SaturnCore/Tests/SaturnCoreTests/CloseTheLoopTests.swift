import Foundation
import GRDB
import Testing
@testable import SaturnCore

@Suite struct AgentInstructionsTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "agents-md-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func setUpWritesALeanTemplateAndPointsClaudeAtIt() throws {
        let repository = try folder()
        defer { try? FileManager.default.removeItem(at: repository) }
        try #"{"scripts":{"test":"vitest run"}}"#.write(to: repository.appending(path: "package.json"), atomically: true, encoding: .utf8)

        #expect(!AgentInstructions.status(repository: repository).isSetUp)
        #expect(try AgentInstructions.setUp(repository: repository) == ["AGENTS.md", "CLAUDE.md"])
        let agents = try String(contentsOf: repository.appending(path: "AGENTS.md"), encoding: .utf8)
        #expect(agents.contains("## Commands\n- Test: `npm test`"))
        #expect(try String(contentsOf: repository.appending(path: "CLAUDE.md"), encoding: .utf8) == "@AGENTS.md\n")
        #expect(AgentInstructions.status(repository: repository).isSetUp)
        #expect(try AgentInstructions.setUp(repository: repository).isEmpty)
    }

    @Test func anExistingClaudeFileIsImported() throws {
        let repository = try folder()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "# Shop\n- Run `make test`\n".write(to: repository.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        try AgentInstructions.setUp(repository: repository)
        #expect(try String(contentsOf: repository.appending(path: "AGENTS.md"), encoding: .utf8) == "# Shop\n- Run `make test`\n")
        #expect(try String(contentsOf: repository.appending(path: "CLAUDE.md"), encoding: .utf8) == "@AGENTS.md\n")
    }

    @Test func learnedRulesGoUnderOneHeadingAndLongFilesAreFlagged() throws {
        let repository = try folder()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "# Shop\n".write(to: repository.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try AgentInstructions.appendLearned("Use Decimal for money", repository: repository)
        try AgentInstructions.appendLearned("- Never call the gateway in a loop", repository: repository)
        let text = try String(contentsOf: repository.appending(path: "AGENTS.md"), encoding: .utf8)
        #expect(text == "# Shop\n\n## Learned from review\n- Use Decimal for money\n- Never call the gateway in a loop\n")
        #expect(!AgentInstructions.status(repository: repository).isTooLong)

        try String(repeating: "- a rule\n", count: 70).write(to: repository.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        #expect(AgentInstructions.status(repository: repository).isTooLong)
    }
}

@MainActor
@Suite(.serialized) struct CorrectionTests {
    struct Setup {
        let repo: TestRepository
        let database: AppDatabase
        let project: Project
    }

    func makeSetup() async throws -> Setup {
        let repo = try await TestRepository.make()
        let database = try AppDatabase.inMemory()
        return Setup(repo: repo, database: database, project: try database.openProject(at: repo.root))
    }

    func makeRun(_ setup: Setup, title: String = "Refunds") throws -> Int64 {
        let projectId = try #require(setup.project.id)
        let task = try setup.database.insert(Chat(projectId: projectId, title: title, body: "", source: .chat, status: .running, createdAt: .now, updatedAt: .now))
        let taskId = try #require(task.id)
        let run = try setup.database.insert(Run(projectId: projectId, taskId: taskId, workflow: "w", status: .running, startedAt: .now, title: title), state: RunEngineState())
        return try #require(run.id)
    }

    @Test func requestedChangesAndCommentsAreRecordedAndRepeatsFlagged() async throws {
        let setup = try await makeSetup()
        defer { setup.repo.delete() }
        let first = try makeRun(setup)
        let pin = try setup.database.createPin(PinDraft(file: "shop/money.py", startLine: 3, endLine: 3, title: "Rounding", explanation: "x"), runId: first, agentId: nil)
        try setup.database.updatePin(id: try #require(pin.id), status: .changeRequested, response: "Use Decimal for money amounts, never float")
        try setup.database.updatePin(id: try #require(pin.id), status: .changeRequested, response: "Use Decimal for money amounts, never floats")
        #expect(try setup.database.corrections(projectId: setup.project.id!).map(\.text) == ["Use Decimal for money amounts, never floats"])

        _ = try setup.database.createComment(runId: first, branchAgentId: nil, file: "shop/tax.py", side: .new, startLine: 1, endLine: 1, text: "Money amounts must use Decimal, never float")
        #expect(try setup.database.openChatRequests(projectId: setup.project.id!).isEmpty)

        let second = try makeRun(setup, title: "Invoices")
        _ = try setup.database.createComment(runId: second, branchAgentId: nil, file: "shop/invoices.py", side: .new, startLine: 9, endLine: 9, text: "Again: money amounts need Decimal, not float")
        let notice = try #require(try setup.database.openChatRequests(projectId: setup.project.id!).last)
        #expect(notice.title == "You’ve asked for this before")
        #expect(notice.body.contains("Settings › Learned Rules"))
        #expect(try setup.database.repeatedCorrections(projectId: setup.project.id!).count == 3)
    }

    @Test func encodingCommitsTheRuleAndRetiresSimilarCorrections() async throws {
        let setup = try await makeSetup()
        defer { setup.repo.delete() }
        let first = try makeRun(setup), second = try makeRun(setup)
        _ = try setup.database.createComment(runId: first, branchAgentId: nil, file: "shop/money.py", side: .new, startLine: 1, endLine: 1, text: "Use Decimal for money amounts")
        _ = try setup.database.createComment(runId: second, branchAgentId: nil, file: "shop/tax.py", side: .new, startLine: 1, endLine: 1, text: "Money amounts should use Decimal")
        let correction = try #require(try setup.database.corrections(projectId: setup.project.id!).last)
        #expect(CorrectionEncoding.suggestions(for: correction) == ("Use Decimal for money amounts (in shop/)", "shop/**"))

        try await setup.database.encode(correction, as: .instruction("Use Decimal for money amounts"), repository: setup.repo.root, git: setup.repo.git)
        let log = try await setup.repo.git.run(["log", "-1", "--format=%s", "--name-only"], in: setup.repo.root)
        #expect(log.hasPrefix("Encode review correction: Use Decimal for money amounts"))
        #expect(log.contains("AGENTS.md") && log.contains("CLAUDE.md"))
        #expect(try String(contentsOf: setup.repo.root.appending(path: "AGENTS.md"), encoding: .utf8).hasSuffix("## Learned from review\n- Use Decimal for money amounts\n"))
        #expect(try setup.database.corrections(projectId: setup.project.id!).allSatisfy(\.isEncoded))
        #expect(try setup.database.repeatedCorrections(projectId: setup.project.id!).isEmpty)
        #expect(try await setup.repo.status().isEmpty)
    }

    @Test func correctionsCanBecomeChecksOrProtectedPaths() async throws {
        let setup = try await makeSetup()
        defer { setup.repo.delete() }
        let run = try makeRun(setup)
        _ = try setup.database.createComment(runId: run, branchAgentId: nil, file: "tests/test_tax.py", side: .new, startLine: 1, endLine: 1, text: "Don't weaken the tax tests")
        let correction = try #require(try setup.database.corrections(projectId: setup.project.id!).first)

        try await setup.database.encode(correction, as: .protectedPath("tests/**"), repository: setup.repo.root, git: setup.repo.git)
        try await setup.database.encode(correction, as: .check(CheckDefinition(name: "types", kind: .typecheck, command: "mypy .")), repository: setup.repo.root, git: setup.repo.git)
        let checks = try #require(ProjectConfigLoader.load(repository: setup.repo.root).checks)
        #expect(checks.protectedPaths == ["tests/**"])
        #expect(checks.checks.map(\.name) == ["types"])
        #expect(try await setup.repo.status().isEmpty)
    }
}

@MainActor
@Suite(.serialized) struct QualityReportTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    let workflow = WorkflowDefinition(id: "w", name: "W", steps: [
        WorkflowStep(id: "build", type: .agent, agent: .builder, next: "checks"),
        WorkflowStep(id: "checks", type: .check, next: "gates"),
        WorkflowStep(id: "gates", type: .gates, next: "approve"),
        WorkflowStep(id: "approve", type: .approval, routes: [StepOutcome.approved: WorkflowRoute(to: "end"), StepOutcome.changesRequested: WorkflowRoute(to: "build")]),
    ])

    func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func encode(_ output: StepOutput) -> String {
        String(decoding: try! JSONEncoder().encode(output), as: UTF8.self)
    }

    func addRun(_ database: AppDatabase, project: Int64, ended: Date, lines: Int, cost: Double, checkRounds: Int, sentBack: Bool, approvalMinutes: Double) throws {
        let task = try database.insert(Chat(projectId: project, title: "T", body: "", source: .chat, status: .done, createdAt: ended, updatedAt: ended))
        let run = try database.insert(Run(
            projectId: project, taskId: try #require(task.id), workflow: "w", status: .succeeded, costUSD: cost, startedAt: ended.addingTimeInterval(-7200),
            endedAt: ended, title: "T", workflowSnapshot: try ProjectConfigLoader.encodeYAML(workflow), linesChanged: lines, filesChanged: 2
        ), state: RunEngineState())
        let runId = try #require(run.id)
        let check = CheckReport(round: checkRounds, results: [CheckResult(name: "unit", kind: .test, command: "pytest", status: .passed)])
        _ = try database.insert(RunStep(runId: runId, stepId: "checks", iteration: 1, status: .succeeded, outcome: "passed", output: encode(StepOutput(checks: [check])), startedAt: ended, endedAt: ended))
        let gates = GateReport(findings: [GateFinding(kind: .duplication, severity: .warning, title: "d", detail: "")])
        _ = try database.insert(RunStep(runId: runId, stepId: "gates", iteration: 1, status: .succeeded, outcome: "passed", output: encode(StepOutput(gates: gates)), startedAt: ended, endedAt: ended))
        if sentBack {
            _ = try database.insert(RunStep(runId: runId, stepId: "approve", iteration: 1, status: .succeeded, outcome: StepOutcome.changesRequested, startedAt: ended, endedAt: ended))
        }
        _ = try database.insert(RunStep(runId: runId, stepId: "approve", iteration: sentBack ? 2 : 1, status: .succeeded, outcome: StepOutcome.approved, startedAt: ended, endedAt: ended))
        var item = try database.createChatRequest(ChatRequest(projectId: project, runId: runId, kind: .approval, title: "Approve", body: "", createdAt: ended.addingTimeInterval(-approvalMinutes * 60)))
        item.status = .answered
        item.resolvedAt = ended
        try database.writer.write { db in try item.update(db) }
    }

    @Test func measuresOutcomesPerWeek() throws {
        let database = try AppDatabase.inMemory()
        let folder = FileManager.default.temporaryDirectory.appending(path: "quality-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try database.openProject(at: folder)
        let projectId = try #require(project.id)
        try addRun(database, project: projectId, ended: date("2026-10-14T10:00:00Z"), lines: 120, cost: 2, checkRounds: 1, sentBack: false, approvalMinutes: 30)
        try addRun(database, project: projectId, ended: date("2026-10-15T10:00:00Z"), lines: 300, cost: 4, checkRounds: 2, sentBack: true, approvalMinutes: 90)
        try addRun(database, project: projectId, ended: date("2026-10-21T10:00:00Z"), lines: 80, cost: 1, checkRounds: 1, sentBack: false, approvalMinutes: 10)

        let report = try database.qualityReport(projectIds: [projectId], weeks: 3, now: date("2026-10-23T10:00:00Z"), calendar: calendar)
        #expect(report.weeks.map(\.approvedChanges) == [0, 2, 1])
        let week = report.weeks[1]
        #expect(week.medianChangeSize == 210)
        #expect(week.medianApprovalMinutes == 60)
        #expect(week.checkFailureRate == 0.5)
        #expect(week.checkRetries == 1)
        #expect(week.reworkRate == 0.5)
        #expect(week.approvals == 3 && week.sentBack == 1)
        #expect(week.duplicationWarnings == 2)
        #expect(week.costPerApprovedChange == 3)
        #expect(report.total.approvedChanges == 3)

        let notice = try #require(try WeeklySummary.postIfDue(for: project, database: database, now: date("2026-10-23T10:00:00Z"), calendar: calendar))
        #expect(notice.title == WeeklySummary.title(project: project, weekStart: date("2026-10-12T00:00:00Z"), calendar: calendar))
        #expect(notice.body.hasPrefix("2 changes approved, median 210 lines.\nMedian time to approve: 60 min."))
        #expect(notice.body.contains("Checks failed the first time in 50% of check steps"))
        #expect(try WeeklySummary.postIfDue(for: project, database: database, now: date("2026-10-24T10:00:00Z"), calendar: calendar) == nil)
    }

    @Test func noActivityMeansNoSummary() throws {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: FileManager.default.temporaryDirectory.appending(path: "quiet-\(UUID().uuidString)"))
        #expect(try WeeklySummary.postIfDue(for: project, database: database, now: .now, calendar: calendar) == nil)
    }

    @Test func runsRecordTheirChangeSizeWhenTheyFinish() async throws {
        let h = try WorkflowHarness.make()
        defer { h.cleanUp() }
        h.driver.diff = DiffInfo(paths: ["a.py", "b.py", "c.py"], lines: 42)
        h.driver.script("build", WorkflowHarness.done())
        let id = try await h.start(WorkflowDefinition(id: "one", name: "One", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)]))
        #expect(try h.run(id).status == .succeeded)
        #expect(try h.run(id).linesChanged == 42)
        #expect(try h.run(id).filesChanged == 3)
    }
}
