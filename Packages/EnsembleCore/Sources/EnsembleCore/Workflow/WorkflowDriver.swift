import Foundation

@MainActor
public protocol WorkflowDriver: AnyObject, Sendable {
    func runAgentStep(_ context: StepContext) async throws -> StepResult
    func runSpawnStep(_ context: SpawnContext) async throws -> StepResult
    func runCheckStep(_ context: StepContext) async throws -> StepResult
    func runGateStep(_ context: StepContext) async throws -> StepResult
    func diffInfo(_ run: Run) async -> DiffInfo
    func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult
    func cancel(_ run: Run) async
    func mergeDelivery(_ run: Run, method: MergeMethod) async throws -> String
    func pushBase(_ run: Run) async throws -> String
}

public enum MergeMethod: String, Sendable, Codable, CaseIterable {
    case mergeCommit
    case squash
    case rebase
}

public struct TaskResult: Sendable, Hashable, Codable {
    public var planTaskId: String
    public var agentName: String?
    public var summary: String

    public init(planTaskId: String, agentName: String? = nil, summary: String) {
        self.planTaskId = planTaskId
        self.agentName = agentName
        self.summary = summary
    }
}

public struct StepOutput: Sendable, Hashable, Codable {
    public var plan: Plan?
    public var verdict: Verdict?
    public var summary: String?
    public var taskResults: [TaskResult]
    public var branchHeads: [String: String]
    public var checks: [CheckReport]
    public var gates: GateReport?

    public init(
        plan: Plan? = nil, verdict: Verdict? = nil, summary: String? = nil, taskResults: [TaskResult] = [],
        branchHeads: [String: String] = [:], checks: [CheckReport] = [], gates: GateReport? = nil
    ) {
        self.gates = gates
        self.plan = plan
        self.verdict = verdict
        self.summary = summary
        self.taskResults = taskResults
        self.branchHeads = branchHeads
        self.checks = checks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.plan = try container.decodeIfPresent(Plan.self, forKey: .plan)
        self.verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.taskResults = try container.decodeIfPresent([TaskResult].self, forKey: .taskResults) ?? []
        self.branchHeads = try container.decodeIfPresent([String: String].self, forKey: .branchHeads) ?? [:]
        self.checks = try container.decodeIfPresent([CheckReport].self, forKey: .checks) ?? []
        self.gates = try container.decodeIfPresent(GateReport.self, forKey: .gates)
    }
}

public struct StepResult: Sendable, Hashable {
    public var outcome: String
    public var output: StepOutput
    public var costUSD: Double

    public init(outcome: String, output: StepOutput = StepOutput(), costUSD: Double = 0) {
        self.outcome = outcome
        self.output = output
        self.costUSD = costUSD
    }

    public static func plan(_ plan: Plan, costUSD: Double = 0) -> StepResult {
        StepResult(outcome: StepOutcome.done, output: StepOutput(plan: plan, summary: plan.summary), costUSD: costUSD)
    }

    public static func verdict(_ verdict: Verdict, costUSD: Double = 0) -> StepResult {
        StepResult(outcome: verdict.outcome, output: StepOutput(verdict: verdict, summary: verdict.summary), costUSD: costUSD)
    }

    public static func done(_ summary: String, taskResults: [TaskResult] = [], branchHeads: [String: String] = [:], costUSD: Double = 0) -> StepResult {
        StepResult(outcome: StepOutcome.done, output: StepOutput(summary: summary, taskResults: taskResults, branchHeads: branchHeads), costUSD: costUSD)
    }
}

public struct PreviousOutput: Sendable, Hashable, Codable {
    public var stepId: String
    public var iteration: Int
    public var outcome: String?
    public var output: StepOutput

    public init(stepId: String, iteration: Int, outcome: String?, output: StepOutput) {
        self.stepId = stepId
        self.iteration = iteration
        self.outcome = outcome
        self.output = output
    }
}

public struct Feedback: Sendable, Hashable, Codable {
    public var fromStep: String
    public var outcome: String
    public var summary: String
    public var issues: [ReviewIssue]

    public init(fromStep: String, outcome: String, summary: String, issues: [ReviewIssue] = []) {
        self.fromStep = fromStep
        self.outcome = outcome
        self.summary = summary
        self.issues = issues
    }
}

public struct StepInputs: Sendable, Hashable, Codable {
    public var taskTitle: String
    public var taskBody: String
    public var labels: [String]
    public var instructions: String
    public var plan: Plan?
    public var latestVerdict: Verdict?
    public var feedback: Feedback?
    public var previousOutputs: [PreviousOutput]

    public init(
        taskTitle: String, taskBody: String, labels: [String] = [], instructions: String = "", plan: Plan? = nil,
        latestVerdict: Verdict? = nil, feedback: Feedback? = nil, previousOutputs: [PreviousOutput] = []
    ) {
        self.taskTitle = taskTitle
        self.taskBody = taskBody
        self.labels = labels
        self.instructions = instructions
        self.plan = plan
        self.latestVerdict = latestVerdict
        self.feedback = feedback
        self.previousOutputs = previousOutputs
    }
}

public struct StepContext: Sendable, Hashable {
    public var run: Run
    public var task: ProjectTask
    public var project: Project
    public var step: WorkflowStep
    public var kind: AgentKind?
    public var iteration: Int
    public var attempt: Int
    public var runStepID: Int64
    public var start: StepStart
    public var inputs: StepInputs
    public var stepBudgetUSD: Double?
    public var runBudgetRemainingUSD: Double?

    public init(
        run: Run, task: ProjectTask, project: Project, step: WorkflowStep, kind: AgentKind?, iteration: Int, attempt: Int,
        runStepID: Int64, start: StepStart, inputs: StepInputs, stepBudgetUSD: Double?, runBudgetRemainingUSD: Double?
    ) {
        self.run = run
        self.task = task
        self.project = project
        self.step = step
        self.kind = kind
        self.iteration = iteration
        self.attempt = attempt
        self.runStepID = runStepID
        self.start = start
        self.inputs = inputs
        self.stepBudgetUSD = stepBudgetUSD
        self.runBudgetRemainingUSD = runBudgetRemainingUSD
    }

    public var isLoopBack: Bool { iteration > 1 }
    public var isResuming: Bool {
        if case .resume = start { return true }
        return false
    }
}

public struct SpawnContext: Sendable, Hashable {
    public var step: StepContext
    public var plan: Plan
    public var maxAgents: Int?

    public init(step: StepContext, plan: Plan, maxAgents: Int?) {
        self.step = step
        self.plan = plan
        self.maxAgents = maxAgents
    }

    public var feedback: Feedback? { step.inputs.feedback }
    public var iteration: Int { step.iteration }
}

public struct DiffInfo: Sendable, Hashable, Codable {
    public var paths: [String]
    public var lines: Int

    public init(paths: [String] = [], lines: Int = 0) {
        self.paths = paths
        self.lines = lines
    }
}

public struct FinishResult: Sendable, Hashable, Codable {
    public var summary: String?
    public var deliveryBranch: String?
    public var baseBranch: String?
    public var mergedIntoBase: Bool

    public init(summary: String? = nil, deliveryBranch: String? = nil, baseBranch: String? = nil, mergedIntoBase: Bool = false) {
        self.summary = summary
        self.mergedIntoBase = mergedIntoBase
        self.deliveryBranch = deliveryBranch
        self.baseBranch = baseBranch
    }
}
