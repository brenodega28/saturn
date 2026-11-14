import Foundation
import Testing
@testable import EnsembleCore

struct ScriptedFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
final class ScriptedWorkflowDriver: WorkflowDriver {
    enum Reply {
        case result(StepResult)
        case failure(String)
        case hang
        case gated(ReplyGate)
    }

    var replies: [String: [Reply]] = [:]
    var finishReplies: [Result<FinishResult, ScriptedFailure>] = []
    var mergeReplies: [Result<String, ScriptedFailure>] = []
    var pushReplies: [Result<String, ScriptedFailure>] = []
    var diff = DiffInfo()
    private(set) var agentCalls: [StepContext] = []
    private(set) var spawnCalls: [SpawnContext] = []
    private(set) var checkCalls: [StepContext] = []
    private(set) var finishCalls: [WorkflowEnd] = []
    private(set) var diffRequests = 0
    private(set) var cancelledRuns: [Int64] = []
    private(set) var mergeCalls: [MergeMethod] = []
    private(set) var pushCalls: [Int64] = []

    func script(_ stepId: String, _ replies: Reply...) {
        self.replies[stepId, default: []] += replies
    }

    var calledSteps: [String] {
        agentCalls.map(\.step.id) + spawnCalls.map(\.step.step.id) + checkCalls.map(\.step.id)
    }

    func runAgentStep(_ context: StepContext) async throws -> StepResult {
        agentCalls.append(context)
        return try await reply(for: context.step.id)
    }

    func runSpawnStep(_ context: SpawnContext) async throws -> StepResult {
        spawnCalls.append(context)
        return try await reply(for: context.step.step.id)
    }

    func runGateStep(_ context: StepContext) async throws -> StepResult {
        checkCalls.append(context)
        return try await reply(for: context.step.id)
    }

    func runCheckStep(_ context: StepContext) async throws -> StepResult {
        checkCalls.append(context)
        return try await reply(for: context.step.id)
    }

    func diffInfo(_ run: Run) async -> DiffInfo {
        diffRequests += 1
        return diff
    }

    func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult {
        finishCalls.append(end)
        guard !finishReplies.isEmpty else {
            return FinishResult(summary: "Merged crew/delivery-run-\(run.id ?? 0) into main.", baseBranch: "main", mergedIntoBase: true)
        }
        return try finishReplies.removeFirst().get()
    }

    func cancel(_ run: Run) async {
        if let id = run.id { cancelledRuns.append(id) }
    }

    func mergeDelivery(_ run: Run, method: MergeMethod) async throws -> String {
        mergeCalls.append(method)
        guard !mergeReplies.isEmpty else { return "Merged \(run.deliveryBranch ?? "") into \(run.baseBranch ?? "")." }
        return try mergeReplies.removeFirst().get()
    }

    func pushBase(_ run: Run) async throws -> String {
        pushCalls.append(run.id ?? 0)
        guard !pushReplies.isEmpty else { return "Pushed \(run.baseBranch ?? "") to origin · abc1234" }
        return try pushReplies.removeFirst().get()
    }

    private func reply(for stepId: String) async throws -> StepResult {
        guard var queue = replies[stepId], !queue.isEmpty else { throw ScriptedFailure(message: "No scripted reply for \(stepId)") }
        let next = queue.removeFirst()
        replies[stepId] = queue
        switch next {
        case .result(let result):
            return result
        case .failure(let message):
            throw ScriptedFailure(message: message)
        case .hang:
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .gated(let gate):
            return await gate.wait()
        }
    }
}

@MainActor
final class ReplyGate {
    private var result: StepResult?
    private var waiter: CheckedContinuation<StepResult, Never>?

    func wait() async -> StepResult {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func open(_ result: StepResult) {
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

@MainActor
struct WorkflowHarness {
    let database: AppDatabase
    let driver: ScriptedWorkflowDriver
    let engine: RunEngine
    let project: Project
    let repository: URL

    static func make(minute: Duration = .seconds(60)) throws -> WorkflowHarness {
        let repository = FileManager.default.temporaryDirectory.appending(path: "ensemble-workflow-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try ProjectConfigLoader.installDefaults(repository: repository)
        try LegacyWorkflows.install(repository: repository)
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: repository)
        let driver = ScriptedWorkflowDriver()
        let engine = RunEngine(database: database, driver: driver, minute: minute)
        return WorkflowHarness(database: database, driver: driver, engine: engine, project: project, repository: repository)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: repository)
    }

    func workflow(_ id: String) throws -> WorkflowDefinition {
        try #require(ProjectConfigLoader.load(repository: repository).workflow(id))
    }

    func makeTask(title: String = "Refunds v2", labels: [String] = []) throws -> ProjectTask {
        let projectId = try #require(project.id)
        return try database.insert(ProjectTask(
            projectId: projectId, title: title, body: "Let support agents refund orders.", source: .chat,
            status: .incoming, labels: labels, createdAt: .now, updatedAt: .now
        ))
    }

    func start(_ workflow: WorkflowDefinition, labels: [String] = []) async throws -> Int64 {
        let run = try engine.start(task: try makeTask(labels: labels), workflow: workflow, project: project)
        let id = try #require(run.id)
        await engine.waitUntilIdle(runID: id)
        return id
    }

    func run(_ id: Int64) throws -> Run {
        try #require(try database.run(id: id))
    }

    func task(of id: Int64) throws -> ProjectTask {
        try #require(try database.task(id: try run(id).taskId))
    }

    func steps(_ id: Int64) throws -> [RunStep] {
        try database.runSteps(runId: id)
    }

    func hold(_ id: Int64) throws -> RunHold? {
        try database.engineState(runId: id).hold
    }

    func settle(_ id: Int64) async {
        await engine.waitUntilIdle(runID: id)
    }

    static let plan = Plan(summary: "Add a refund endpoint and a button.", tasks: [
        PlanTask(id: "api", title: "Refund API"),
        PlanTask(id: "ui", title: "Refund button"),
    ])

    static func verdict(_ outcome: String, _ summary: String = "", issues: [ReviewIssue] = [], cost: Double = 0) -> ScriptedWorkflowDriver.Reply {
        .result(.verdict(Verdict(outcome: outcome, summary: summary, issues: issues), costUSD: cost))
    }

    static func done(_ summary: String = "Built it", heads: [String: String] = [:], cost: Double = 0) -> ScriptedWorkflowDriver.Reply {
        .result(.done(summary, branchHeads: heads, costUSD: cost))
    }
}
