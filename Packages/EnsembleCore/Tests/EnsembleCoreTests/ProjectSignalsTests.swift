import Foundation
import Testing
import Yams
@testable import EnsembleCore

struct ProjectSignalsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func run(_ id: Int64, status: RunStatus = .running, title: String = "Refunds v2") throws -> Run {
        let workflow = WorkflowDefinition(
            id: "feature", name: "Feature",
            steps: [
                WorkflowStep(id: "build", type: .agent, role: "claude-code", instructions: "Build it.", next: "checks"),
                WorkflowStep(id: "checks", type: .check, next: "gates"),
                WorkflowStep(id: "gates", type: .gates, next: "end"),
            ],
            end: WorkflowEnd(action: .leave, cleanUpWorktrees: false)
        )
        return Run(
            id: id, projectId: 1, taskId: id, workflow: "feature", status: status, startedAt: start,
            title: title, workflowSnapshot: try YAMLEncoder().encode(workflow)
        )
    }

    func step(_ runId: Int64, _ stepId: String, status: RunStepStatus, output: StepOutput? = nil, at offset: TimeInterval) throws -> RunStep {
        let text = try output.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        return RunStep(runId: runId, stepId: stepId, status: status, output: text, startedAt: start.addingTimeInterval(offset))
    }

    func report(_ agent: String, round: Int = 1, passing: Bool) -> CheckReport {
        CheckReport(agentName: agent, branch: "crew/\(agent)/refunds", round: round, results: [
            CheckResult(name: "lint", kind: .lint, command: "ruff check .", status: .passed),
            CheckResult(name: "tests", kind: .test, command: "pytest", status: passing ? .passed : .failed, exitCode: passing ? 0 : 1),
        ])
    }

    @Test func theCheckBoardShowsTheLatestReportPerBuilder() throws {
        let runs = [try run(1)]
        let steps: [Int64: [RunStep]] = [1: [
            try step(1, "checks", status: .succeeded, output: StepOutput(checks: [report("django-1", passing: false)]), at: 0),
            try step(1, "checks", status: .succeeded, output: StepOutput(checks: [report("django-1", round: 2, passing: true), report("react-1", passing: true)]), at: 10),
        ]]

        let board = ProjectSignals.checkBoard(runs: runs, steps: steps)

        #expect(board.map(\.agentName) == ["django-1", "react-1"])
        #expect(board.map(\.state) == [.passed, .passed])
        #expect(board.first?.round == 2)
    }

    @Test func aRunningCheckStepShowsTheNextRoundAsRunning() throws {
        let steps: [Int64: [RunStep]] = [1: [
            try step(1, "checks", status: .succeeded, output: StepOutput(checks: [report("django-1", passing: true)]), at: 0),
            try step(1, "checks", status: .running, at: 10),
        ]]

        let board = ProjectSignals.checkBoard(runs: [try run(1)], steps: steps)

        #expect(board.map(\.state) == [.running])
        #expect(board.first?.round == 2)
    }

    @Test func exhaustedChecksBecomeAFailingProblem() throws {
        let hold = RunHold(reason: .stepFailed, stepId: "checks", message: "Checks still failed after 2 rounds.\n\n## tests failed")
        let runs = [try run(1)]

        let board = ProjectSignals.checkBoard(runs: runs, steps: [1: [try step(1, "checks", status: .failed, at: 0)]], holds: [1: hold])
        let problems = ProjectSignals.problems(runs: runs, steps: [:], holds: [1: hold])

        #expect(board.map(\.state) == [.exhausted])
        #expect(board.first?.message == "Checks still failed after 2 rounds.")
        #expect(problems.map(\.category) == [.failingChecks])
        #expect(problems.first?.title == "Checks still failed after 2 rounds.")
        #expect(problems.first?.runId == 1)
    }

    @Test func finishedRunsDontReportProblems() throws {
        let gates = GateReport(findings: [GateFinding(kind: .complexity, severity: .warning, title: "create_refund complexity 9", detail: "", file: "orders/views.py", line: 46)])
        let steps: [Int64: [RunStep]] = [1: [try step(1, "gates", status: .succeeded, output: StepOutput(gates: gates), at: 0)]]

        #expect(ProjectSignals.problems(runs: [try run(1, status: .succeeded)], steps: steps).isEmpty)
        #expect(ProjectSignals.checkBoard(runs: [try run(1, status: .failed)], steps: steps).isEmpty)
    }

    @Test func gateFindingsConfigErrorsAndMissingSkillsAreCollected() throws {
        let gates = GateReport(findings: [
            GateFinding(kind: .dependency, severity: .blocking, title: "New dependency left-pad needs a decision", detail: "", file: "package.json"),
            GateFinding(kind: .complexity, severity: .warning, title: "create_refund complexity 9", detail: "", file: "orders/views.py", line: 46),
        ])
        let steps: [Int64: [RunStep]] = [1: [try step(1, "gates", status: .succeeded, output: StepOutput(gates: gates), at: 0)]]
        let roles = [
            RoleDefinition(id: "django", name: "Django Developer", skills: ["django-dev", "design-tokens"]),
            RoleDefinition(id: "react", name: "React Developer", skills: ["design-tokens"]),
        ]

        let problems = ProjectSignals.problems(
            runs: [try run(1)], steps: steps,
            configIssues: [ConfigIssue(file: ".ensemble/checks.yaml", message: "Unknown check kind “typo”")],
            roles: roles, installedSkills: ["django-dev"]
        )

        #expect(problems.map(\.category) == [.gateFindings, .gateFindings, .configErrors, .missingSkills])
        #expect(problems.map(\.severity) == [.error, .warning, .error, .warning])
        #expect(problems[1].location == "orders/views.py:46 · Refunds v2")
        #expect(problems[3].title == "design-tokens is forced by a role but isn’t installed")
        #expect(problems[3].location == "Django Developer, React Developer")
    }
}
