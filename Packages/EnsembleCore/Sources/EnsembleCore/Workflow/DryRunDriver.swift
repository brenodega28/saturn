import Foundation

public struct DryRunScript: Sendable, Hashable {
    public var taskTitle: String
    public var taskBody: String
    public var labels: [String]
    public var diff: DiffInfo
    public var outcomes: [String: [String]]

    public init(
        taskTitle: String = "Sample task", taskBody: String = "A dry run with every agent stubbed.", labels: [String] = [],
        diff: DiffInfo = DiffInfo(paths: ["src/app.swift"], lines: 40), outcomes: [String: [String]] = [:]
    ) {
        self.taskTitle = taskTitle
        self.taskBody = taskBody
        self.labels = labels
        self.diff = diff
        self.outcomes = outcomes
    }

    public static func happyPath(for workflow: WorkflowDefinition) -> DryRunScript {
        DryRunScript(labels: workflow.trigger.labels)
    }

    public func outcome(for step: WorkflowStep, iteration: Int) -> String {
        let scripted = outcomes[step.id] ?? []
        let index = iteration - 1
        if scripted.indices.contains(index) { return scripted[index] }
        return Self.happyOutcome(for: step)
    }

    public static func options(for step: WorkflowStep) -> [String] {
        switch step.type {
        case .approval:
            return [StepOutcome.approved, StepOutcome.changesRequested]
        case .condition:
            return []
        case .notify:
            return [StepOutcome.done]
        case .agent, .spawn:
            var options = step.routes.keys.sorted()
            if (step.next != nil || step.routes.isEmpty) && !options.contains(StepOutcome.done) {
                options.append(StepOutcome.done)
            }
            return options
        }
    }

    public static func happyOutcome(for step: WorkflowStep) -> String {
        let options = options(for: step)
        let preferred = [StepOutcome.approved, StepOutcome.passed, StepOutcome.yes, StepOutcome.done]
        return preferred.first { options.contains($0) } ?? options.first ?? StepOutcome.done
    }
}

@MainActor
public final class DryRunDriver: WorkflowDriver {
    public let workflow: WorkflowDefinition
    public let script: DryRunScript
    public private(set) var calledSteps: [String] = []
    public private(set) var finishedWith: WorkflowEnd?

    public init(workflow: WorkflowDefinition, script: DryRunScript) {
        self.workflow = workflow
        self.script = script
    }

    public func runAgentStep(_ context: StepContext) async throws -> StepResult {
        calledSteps.append(context.step.id)
        let outcome = script.outcome(for: context.step, iteration: context.iteration)
        let title = context.step.displayTitle
        if context.inputs.plan == nil, let spawn = spawnStep(after: context.step.id) {
            let plan = Self.samplePlan(for: spawn)
            return StepResult(outcome: outcome, output: StepOutput(plan: plan, summary: plan.summary))
        }
        if outcome == StepOutcome.done {
            return .done("Dry run: “\(title)” finished.")
        }
        return .verdict(Verdict(outcome: outcome, summary: "Dry run: “\(title)” answered \(outcome)."))
    }

    public func runSpawnStep(_ context: SpawnContext) async throws -> StepResult {
        calledSteps.append(context.step.step.id)
        let outcome = script.outcome(for: context.step.step, iteration: context.iteration)
        let results = context.plan.tasks.map { TaskResult(planTaskId: $0.id, agentName: "Stub \($0.role)", summary: "Dry run: built “\($0.title)”.") }
        return StepResult(outcome: outcome, output: StepOutput(summary: "Dry run: \(results.count) stubbed agents finished.", taskResults: results))
    }

    public func diffInfo(_ run: Run) async -> DiffInfo {
        script.diff
    }

    public func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult {
        finishedWith = end
        return FinishResult(summary: "Dry run: would \(Self.describe(end.action)).")
    }

    public func cancel(_ run: Run) async {}

    private func spawnStep(after stepID: String) -> WorkflowStep? {
        guard let index = workflow.index(of: stepID) else { return nil }
        return workflow.steps[(index + 1)...].first { $0.type == .spawn }
    }

    static func samplePlan(for spawn: WorkflowStep) -> Plan {
        let role = spawn.role ?? "claude-code"
        let count = min(max(spawn.maxAgents ?? 2, 1), 2)
        return Plan(summary: "Dry run plan", tasks: (1...count).map {
            PlanTask(id: "sample-\($0)", title: "Sample task \($0)", role: role)
        })
    }

    public static func describe(_ action: EndAction) -> String {
        switch action {
        case .pullRequest: "open a pull request"
        case .merge: "merge into the base branch"
        case .push: "push the branch"
        case .leave: "leave the branches as they are"
        }
    }
}

public struct DryRunStep: Sendable, Hashable, Identifiable {
    public var id: Int
    public var stepId: String
    public var iteration: Int
    public var status: RunStepStatus
    public var outcome: String?
    public var summary: String?

    public init(id: Int, stepId: String, iteration: Int, status: RunStepStatus, outcome: String?, summary: String?) {
        self.id = id
        self.stepId = stepId
        self.iteration = iteration
        self.status = status
        self.outcome = outcome
        self.summary = summary
    }
}

public struct DryRunTransition: Sendable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct DryRunReport: Sendable, Hashable {
    public var steps: [DryRunStep]
    public var status: RunStatus
    public var error: String?
    public var notes: [String]

    public init(steps: [DryRunStep], status: RunStatus, error: String? = nil, notes: [String] = []) {
        self.steps = steps
        self.status = status
        self.error = error
        self.notes = notes
    }

    public var path: [String] {
        var path = [WorkflowDefinition.triggerNodeID]
        for step in steps where path.last != step.stepId {
            path.append(step.stepId)
        }
        return path
    }

    public var visitedNodes: Set<String> { Set(path) }

    public var transitions: Set<DryRunTransition> {
        let path = path
        return Set(zip(path, path.dropFirst()).map { DryRunTransition(from: $0, to: $1) })
    }

    public func visits(of nodeID: String) -> Int {
        steps.filter { $0.stepId == nodeID }.map(\.iteration).max() ?? 0
    }
}

@MainActor
public enum DryRun {
    public static func run(_ workflow: WorkflowDefinition, script: DryRunScript, maxDecisions: Int = 100) async throws -> DryRunReport {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: FileManager.default.temporaryDirectory.appending(path: "ensemble-dry-run", directoryHint: .isDirectory))
        guard let projectId = project.id else { throw RunEngineError.invalidState("The dry run couldn’t create a project.") }
        let task = try database.insert(ProjectTask(
            projectId: projectId, title: script.taskTitle, body: script.taskBody, source: .chat, status: .incoming,
            labels: script.labels, createdAt: .now, updatedAt: .now
        ))
        let driver = DryRunDriver(workflow: workflow, script: script)
        let engine = RunEngine(database: database, driver: driver)
        var dryWorkflow = workflow
        if dryWorkflow.id.isEmpty { dryWorkflow.id = "dry-run" }
        let started = try engine.start(task: task, workflow: dryWorkflow, project: project)
        guard let runID = started.id else { throw RunEngineError.runNotFound }
        var notes: [String] = []
        var decisions = 0
        while true {
            await engine.waitUntilIdle(runID: runID)
            guard let run = try database.run(id: runID), run.isActive else { break }
            guard let hold = try database.engineState(runId: runID).hold else {
                if engine.isDriving(runID: runID) { continue }
                break
            }
            decisions += 1
            if decisions > maxDecisions {
                notes.append("Stopped after \(maxDecisions) decisions.")
                try await engine.cancel(run)
                break
            }
            try resolve(hold, run: run, workflow: dryWorkflow, script: script, engine: engine, database: database, notes: &notes)
        }
        guard let finished = try database.run(id: runID) else { throw RunEngineError.runNotFound }
        let steps = try database.runSteps(runId: runID).enumerated().map { index, row in
            DryRunStep(
                id: index, stepId: row.stepId, iteration: row.iteration, status: row.status, outcome: row.outcome,
                summary: row.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.summary
            )
        }
        return DryRunReport(steps: steps, status: finished.status, error: finished.lastError, notes: notes)
    }

    private static func resolve(
        _ hold: RunHold, run: Run, workflow: WorkflowDefinition, script: DryRunScript, engine: RunEngine,
        database: AppDatabase, notes: inout [String]
    ) throws {
        let title = workflow.step(hold.stepId)?.displayTitle ?? hold.stepId
        switch hold.reason {
        case .planApproval:
            let output = try hold.runStepId.flatMap { try database.runStep(id: $0) }?.output
            let plan = output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan
            guard let plan else { throw RunEngineError.invalidState("The dry-run plan is missing.") }
            notes.append("Plan from “\(title)” approved automatically.")
            try engine.approvePlan(run, plan: plan)
        case .approval:
            let iteration = try hold.runStepId.flatMap { try database.runStep(id: $0) }?.iteration ?? 1
            let outcome = workflow.step(hold.stepId).map { script.outcome(for: $0, iteration: iteration) } ?? StepOutcome.approved
            let approved = outcome == StepOutcome.approved
            notes.append("“\(title)” \(approved ? "approved" : "sent back with changes") by the script.")
            try engine.resolveApproval(run, approved: approved, note: "Dry run")
        case .loopLimit:
            notes.append("“\(title)” hit its loop limit; the run stops here.")
            try engine.resolveLoopLimit(run, continueOnce: false)
        case .stepBudget, .runBudget:
            notes.append("Budget check at “\(title)” passed automatically.")
            try engine.resolveBudget(run, proceed: true)
        case .stepFailed, .timedOut:
            notes.append(hold.message)
            try engine.resolveFailure(run, retry: false)
        }
    }
}
