import Foundation
import Testing
@testable import EnsembleCore

struct ChatChecksTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let workflow = WorkflowDefinition(id: "w", name: "W", steps: [
        WorkflowStep(id: "build", type: .agent, agent: .builder),
        WorkflowStep(id: "checks", type: .check, maxRounds: 2),
    ])
    let run = Run(id: 7, projectId: 1, taskId: 1, workflow: "w", status: .running, startedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func result(_ name: String, _ status: CheckResult.Status, seconds: Double = 3) -> CheckResult {
        CheckResult(name: name, kind: .test, command: name, status: status, durationSeconds: seconds)
    }

    func checkStep(iteration: Int, status: RunStepStatus, reports: [CheckReport], minute: Double) throws -> RunStep {
        let output = String(decoding: try JSONEncoder().encode(StepOutput(checks: reports)), as: UTF8.self)
        return RunStep(id: Int64(iteration), runId: 7, stepId: "checks", iteration: iteration, status: status, output: output, startedAt: start.addingTimeInterval(minute * 60))
    }

    @Test func beforeAnyWorkerTheChecksWait() {
        #expect(ChatChecks.make(run: nil, workflow: nil, steps: [], hold: nil, hasWorkers: false).state == .waitingForWorkers)
        #expect(ChatChecks.make(run: run, workflow: workflow, steps: [], hold: nil, hasWorkers: true).state == .notStarted)
    }

    @Test func aFailingRoundListsEachCheckOnce() throws {
        let reports = [
            CheckReport(agentName: "React Dev", round: 2, results: [result("Lint", .passed), result("Tests", .passed, seconds: 12)]),
            CheckReport(agentName: "Django Dev 1", round: 2, results: [result("Lint", .passed, seconds: 5), result("Tests", .failed, seconds: 30)]),
        ]
        let steps = [try checkStep(iteration: 2, status: .failed, reports: reports, minute: 2)]

        let checks = ChatChecks.make(run: run, workflow: workflow, steps: steps, hold: nil, hasWorkers: true)

        #expect(checks.state == .failed(round: 2, maxRounds: 2))
        #expect(checks.rows.map(\.name) == ["Lint", "Tests"])
        #expect(checks.rows.map(\.status) == [.passed, .failed])
        #expect(checks.rows.map(\.durationSeconds) == [5, 30])
    }

    @Test func runningPassedAndExhaustedRounds() throws {
        let green = [CheckReport(round: 1, results: [result("Lint", .passed), result("Build", .passed)])]
        let passed = [try checkStep(iteration: 1, status: .succeeded, reports: green, minute: 1)]
        #expect(ChatChecks.make(run: run, workflow: workflow, steps: passed, hold: nil, hasWorkers: true).state == .passed(count: 2))

        let running = passed + [try checkStep(iteration: 2, status: .running, reports: [], minute: 3)]
        let live = ChatChecks.make(run: run, workflow: workflow, steps: running, hold: nil, hasWorkers: true)
        #expect(live.state == .running(round: 2))
        #expect(live.rows.allSatisfy { $0.status == .running })

        let hold = RunHold(reason: .stepFailed, stepId: "checks", message: "Out of retries")
        let red = [try checkStep(iteration: 2, status: .failed, reports: [CheckReport(round: 2, results: [result("Tests", .failed)])], minute: 4)]
        #expect(ChatChecks.make(run: run, workflow: workflow, steps: red, hold: hold, hasWorkers: true).state == .exhausted(round: 2))
    }
}
