import Foundation

extension RunEngine {
    func drive(_ runID: Int64) async {
        while !Task.isCancelled {
            do {
                guard try await advance(runID) else { return }
            } catch {
                guard !Task.isCancelled, var loaded = try? load(runID), loaded.run.status == .running else { return }
                try? fail(&loaded, message: error.localizedDescription)
                return
            }
        }
    }

    private func advance(_ runID: Int64) async throws -> Bool {
        var loaded = try load(runID)
        guard loaded.run.status == .running, loaded.state.hold == nil, let cursor = loaded.state.cursor else { return false }
        if cursor.stepId == WorkflowDefinition.endStepID {
            return try await finish(&loaded, cursor: cursor)
        }
        guard let step = loaded.workflow.step(cursor.stepId) else { throw RunEngineError.unknownStep(cursor.stepId) }
        if let budget = loaded.run.budgetUSD, loaded.run.costUSD >= budget {
            try hold(
                &loaded, .runBudget, stepId: step.id,
                title: "“\(loaded.run.title)” reached its \(Self.dollars(budget)) budget",
                body: "The run has spent \(Self.dollars(loaded.run.costUSD)) before “\(step.displayTitle)”. Raise the budget to continue, or fail the run."
            )
            return false
        }
        switch step.type {
        case .agent, .spawn:
            return try await executeWork(&loaded, step: step, cursor: cursor)
        case .condition:
            return try await executeCondition(&loaded, step: step, cursor: cursor)
        case .approval:
            let runStep = try beginStep(&loaded, stepId: step.id, cursor: cursor, status: .waitingOnYou)
            try hold(
                &loaded, .approval, stepId: step.id, runStepId: runStep.id,
                title: step.displayTitle,
                body: step.message ?? (step.instructions.isEmpty ? "Approve “\(loaded.run.title)” or send it back with changes." : step.instructions)
            )
            return false
        case .notify:
            return try executeNotify(&loaded, step: step, cursor: cursor)
        }
    }

    private func executeWork(_ loaded: inout LoadedRun, step: WorkflowStep, cursor: RunCursor) async throws -> Bool {
        let runID = try loaded.id
        let (task, project) = try taskAndProject(of: loaded.run)
        let inputs = try makeInputs(loaded, step: step, task: task)
        let runStep = try beginStep(&loaded, stepId: step.id, cursor: cursor, status: .running, input: encode(inputs))
        guard let runStepID = runStep.id else { throw RunEngineError.runNotFound }
        let context = StepContext(
            run: loaded.run, task: task, project: project, step: step, roleID: step.role, iteration: cursor.iteration,
            attempt: cursor.attempt, runStepID: runStepID, start: cursor.start, inputs: inputs, stepBudgetUSD: step.budget,
            runBudgetRemainingUSD: loaded.run.budgetUSD.map { max(0, $0 - loaded.run.costUSD) }
        )
        let driver = self.driver
        let result: Result<StepResult, any Error>
        if step.type == .spawn {
            guard let plan = inputs.plan else {
                return try handleFailure(runID: runID, stepId: step.id, onFailure: step.onFailure, runStepID: runStepID, error: RunEngineError.noApprovedPlan)
            }
            let spawn = SpawnContext(step: context, plan: plan, maxAgents: step.maxAgents)
            result = await race(stepId: step.id, timeoutMinutes: step.timeoutMinutes) { try await driver.runSpawnStep(spawn) }
        } else {
            result = await race(stepId: step.id, timeoutMinutes: step.timeoutMinutes) { try await driver.runAgentStep(context) }
        }
        guard !Task.isCancelled, try isStillRunning(runStepID) else { return false }
        switch result {
        case .failure(let error):
            return try handleFailure(runID: runID, stepId: step.id, onFailure: step.onFailure, runStepID: runStepID, error: error)
        case .success(let value):
            return try completeWork(runID: runID, step: step, runStepID: runStepID, result: value)
        }
    }

    private func completeWork(runID: Int64, step: WorkflowStep, runStepID: Int64, result: StepResult) throws -> Bool {
        var loaded = try load(runID)
        guard var runStep = try database.runStep(id: runStepID) else { throw RunEngineError.runNotFound }
        runStep.costUSD = result.costUSD
        runStep.outcome = result.outcome
        runStep.output = encode(result.output)
        loaded.run.costUSD += result.costUSD
        if step.type == .agent, let plan = result.output.plan {
            runStep.status = .waitingOnYou
            try hold(
                &loaded, .planApproval, stepId: step.id, runStepId: runStepID, outcome: result.outcome,
                title: "Approve the plan for “\(loaded.run.title)”",
                body: Self.describe(plan), steps: [runStep]
            )
            return false
        }
        runStep.status = .succeeded
        runStep.endedAt = clock()
        loaded.run.lastError = nil
        return try conclude(&loaded, step: step, outcome: result.outcome, runStep: runStep, output: result.output, checkStepBudget: true)
    }

    private func executeCondition(_ loaded: inout LoadedRun, step: WorkflowStep, cursor: RunCursor) async throws -> Bool {
        let runID = try loaded.id
        let (task, _) = try taskAndProject(of: loaded.run)
        let runStep = try beginStep(&loaded, stepId: step.id, cursor: cursor, status: .running, input: encode(step.condition))
        guard let runStepID = runStep.id else { throw RunEngineError.runNotFound }
        var diff: DiffInfo?
        if step.condition?.needsDiff == true {
            diff = await driver.diffInfo(loaded.run)
            guard !Task.isCancelled, try isStillRunning(runStepID) else { return false }
        }
        let outcomes = try database.runSteps(runId: runID)
            .filter { $0.status == .succeeded }
            .reduce(into: [String: String]()) { result, row in
                if let outcome = row.outcome { result[row.stepId] = outcome }
            }
        let matched = step.condition?.evaluate(ConditionFacts(labels: task.labels, diff: diff, outcomes: outcomes)) ?? false
        let outcome = matched ? StepOutcome.yes : StepOutcome.no
        let output = StepOutput(summary: diff.map { "\($0.paths.count) files, \($0.lines) lines changed" })
        var loadedAfter = try load(runID)
        guard var finished = try database.runStep(id: runStepID) else { throw RunEngineError.runNotFound }
        finished.status = .succeeded
        finished.outcome = outcome
        finished.output = encode(output)
        finished.endedAt = clock()
        let advanced = try conclude(&loadedAfter, step: step, outcome: outcome, runStep: finished, output: output, checkStepBudget: false)
        loaded = loadedAfter
        return advanced
    }

    private func executeNotify(_ loaded: inout LoadedRun, step: WorkflowStep, cursor: RunCursor) throws -> Bool {
        var runStep = try beginStep(&loaded, stepId: step.id, cursor: cursor, status: .running)
        let message = step.message ?? step.displayTitle
        try database.createInboxItem(InboxItem(
            projectId: loaded.run.projectId, runId: loaded.run.id, kind: .notice,
            title: step.displayTitle, body: message, createdAt: clock()
        ))
        let output = StepOutput(summary: message)
        runStep.status = .succeeded
        runStep.outcome = StepOutcome.done
        runStep.output = encode(output)
        runStep.endedAt = clock()
        return try conclude(&loaded, step: step, outcome: StepOutcome.done, runStep: runStep, output: output, checkStepBudget: false)
    }

    private func finish(_ loaded: inout LoadedRun, cursor: RunCursor) async throws -> Bool {
        let runID = try loaded.id
        let runStep = try beginStep(&loaded, stepId: WorkflowDefinition.endStepID, cursor: cursor, status: .running, input: encode(loaded.workflow.end))
        guard let runStepID = runStep.id else { throw RunEngineError.runNotFound }
        let driver = self.driver
        let run = loaded.run
        let end = loaded.workflow.end
        let result = await race(stepId: WorkflowDefinition.endStepID, timeoutMinutes: nil) { try await driver.finish(run, end: end) }
        guard !Task.isCancelled, try isStillRunning(runStepID) else { return false }
        switch result {
        case .failure(let error):
            return try handleFailure(runID: runID, stepId: WorkflowDefinition.endStepID, onFailure: .ask, runStepID: runStepID, error: error)
        case .success(let finished):
            var done = try load(runID)
            guard var row = try database.runStep(id: runStepID) else { throw RunEngineError.runNotFound }
            let now = clock()
            row.status = .succeeded
            row.outcome = StepOutcome.done
            row.output = encode(StepOutput(summary: finished.summary ?? finished.pullRequestURL))
            row.endedAt = now
            done.run.pullRequestURL = finished.pullRequestURL ?? done.run.pullRequestURL
            done.run.status = .succeeded
            done.run.currentStep = WorkflowDefinition.endStepID
            done.run.lastError = nil
            done.run.endedAt = now
            done.state.cursor = nil
            done.state.feedback = nil
            try commit(done, steps: [row])
            loaded = done
            return false
        }
    }

    func conclude(_ loaded: inout LoadedRun, step: WorkflowStep, outcome: String, runStep: RunStep?, output: StepOutput, checkStepBudget: Bool) throws -> Bool {
        let steps = runStep.map { [$0] } ?? []
        if checkStepBudget, let limit = step.budget, let cost = runStep?.costUSD, cost > limit {
            try hold(
                &loaded, .stepBudget, stepId: step.id, runStepId: runStep?.id, outcome: outcome,
                title: "“\(step.displayTitle)” went over its \(Self.dollars(limit)) budget",
                body: "The step cost \(Self.dollars(cost)). Continue with its result, or fail the run.", steps: steps
            )
            return false
        }
        if let budget = loaded.run.budgetUSD, loaded.run.costUSD > budget {
            try hold(
                &loaded, .runBudget, stepId: step.id, runStepId: runStep?.id, outcome: outcome,
                title: "“\(loaded.run.title)” went over its \(Self.dollars(budget)) budget",
                body: "The run has spent \(Self.dollars(loaded.run.costUSD)). Raise the budget to continue, or fail the run.", steps: steps
            )
            return false
        }
        return try route(&loaded, from: step, outcome: outcome, output: output, steps: steps)
    }

    func route(_ loaded: inout LoadedRun, from step: WorkflowStep, outcome: String, output: StepOutput, steps: [RunStep]) throws -> Bool {
        let runID = try loaded.id
        guard let target = Self.target(of: step, outcome: outcome, in: loaded.workflow) else {
            let error = RunEngineError.unroutedOutcome(step: step.id, outcome: outcome)
            try hold(
                &loaded, .stepFailed, stepId: step.id, runStepId: steps.last?.id, outcome: outcome,
                title: "“\(step.displayTitle)” has no route for “\(outcome)”",
                body: error.localizedDescription, steps: steps
            )
            return false
        }
        let key = RunEngineState.loopKey(from: step.id, outcome: outcome)
        let used = loaded.state.loopCounts[key] ?? 0
        if let maxLoops = target.route?.maxLoops, used >= maxLoops + (loaded.state.extraLoops[key] ?? 0) {
            let destination = loaded.workflow.step(target.stepId)?.displayTitle ?? target.stepId
            try hold(
                &loaded, .loopLimit, stepId: step.id, runStepId: steps.last?.id, outcome: outcome,
                title: "“\(step.displayTitle)” sent work back to “\(destination)” \(used) times",
                body: "The loop limit is \(maxLoops). Continue once more, or fail the run.", steps: steps
            )
            return false
        }
        loaded.state.loopCounts[key] = used + 1
        loaded.state.feedback = Self.isLoopBack(from: step.id, to: target.stepId, in: loaded.workflow)
            ? Feedback(fromStep: step.id, outcome: outcome, summary: output.verdict?.summary ?? output.summary ?? "", issues: output.verdict?.issues ?? [])
            : nil
        let iteration = target.stepId == WorkflowDefinition.endStepID ? 1 : try nextIteration(of: target.stepId, runID: runID)
        loaded.state.cursor = RunCursor(stepId: target.stepId, iteration: iteration)
        loaded.run.currentStep = target.stepId
        loaded.run.status = .running
        try commit(loaded, steps: steps)
        return true
    }

    func handleFailure(runID: Int64, stepId: String, onFailure: FailureAction, runStepID: Int64, error: any Error) throws -> Bool {
        var loaded = try load(runID)
        let message = error.localizedDescription
        var steps: [RunStep] = []
        if var row = try database.runStep(id: runStepID) {
            row.status = .failed
            row.output = encode(StepOutput(summary: message))
            row.endedAt = clock()
            steps = [row]
        }
        loaded.run.lastError = message
        let title = loaded.workflow.step(stepId)?.displayTitle ?? stepId
        if case .timedOut? = error as? RunEngineError {
            try hold(&loaded, .timedOut, stepId: stepId, runStepId: runStepID, title: "“\(title)” timed out", body: "\(message) Retry the step, or fail the run.", steps: steps)
            return false
        }
        switch onFailure {
        case .retry where (loaded.state.cursor?.attempt ?? 1) < 2:
            loaded.state.cursor?.attempt += 1
            loaded.state.cursor?.start = .retry(previousRunStepID: runStepID)
            try commit(loaded, steps: steps)
            return true
        case .fail:
            try fail(&loaded, message: message, steps: steps)
            return false
        case .retry, .ask:
            try hold(&loaded, .stepFailed, stepId: stepId, runStepId: runStepID, title: "“\(title)” failed", body: "\(message) Retry the step, or fail the run.", steps: steps)
            return false
        }
    }

    func hold(
        _ loaded: inout LoadedRun, _ reason: HoldReason, stepId: String, runStepId: Int64? = nil, outcome: String? = nil,
        title: String, body: String, steps: [RunStep] = []
    ) throws {
        loaded.state.hold = RunHold(reason: reason, stepId: stepId, runStepId: runStepId, outcome: outcome, message: title)
        loaded.run.status = .waitingOnYou
        let item = InboxItem(projectId: loaded.run.projectId, runId: loaded.run.id, kind: reason.inboxKind, title: title, body: body, createdAt: clock())
        try commit(loaded, steps: steps, inbox: item)
        loaded.state = try database.engineState(runId: try loaded.id)
    }

    private func beginStep(_ loaded: inout LoadedRun, stepId: String, cursor: RunCursor, status: RunStepStatus, input: String? = nil) throws -> RunStep {
        let row = try database.insert(RunStep(
            runId: try loaded.id, stepId: stepId, iteration: cursor.iteration, status: status, input: input, startedAt: clock()
        ))
        loaded.run.currentStep = stepId
        try commit(loaded)
        return row
    }

    private func isStillRunning(_ runStepID: Int64) throws -> Bool {
        try database.runStep(id: runStepID)?.status == .running
    }

    private func taskAndProject(of run: Run) throws -> (ProjectTask, Project) {
        guard let task = try database.task(id: run.taskId), let project = try database.project(id: run.projectId) else {
            throw RunEngineError.invalidState("The run’s task or project was deleted.")
        }
        return (task, project)
    }

    private func makeInputs(_ loaded: LoadedRun, step: WorkflowStep, task: ProjectTask) throws -> StepInputs {
        let previous = try database.runSteps(runId: try loaded.id)
            .filter { $0.status == .succeeded }
            .map { PreviousOutput(stepId: $0.stepId, iteration: $0.iteration, outcome: $0.outcome, output: decodeOutput($0.output)) }
        return StepInputs(
            taskTitle: task.title, taskBody: task.body, labels: task.labels, instructions: step.instructions,
            plan: previous.last { $0.output.plan != nil }?.output.plan,
            latestVerdict: previous.last { $0.output.verdict != nil }?.output.verdict,
            feedback: loaded.state.feedback, previousOutputs: previous
        )
    }

    static func target(of step: WorkflowStep, outcome: String, in workflow: WorkflowDefinition) -> (stepId: String, route: WorkflowRoute?)? {
        if let route = step.routes[outcome] { return (route.to, route) }
        if let next = step.next { return (next, nil) }
        guard step.routes.isEmpty else { return nil }
        guard let index = workflow.steps.firstIndex(where: { $0.id == step.id }), index + 1 < workflow.steps.count else {
            return (WorkflowDefinition.endStepID, nil)
        }
        return (workflow.steps[index + 1].id, nil)
    }

    static func isLoopBack(from source: String, to target: String, in workflow: WorkflowDefinition) -> Bool {
        guard let from = workflow.steps.firstIndex(where: { $0.id == source }),
              let to = workflow.steps.firstIndex(where: { $0.id == target }) else { return false }
        return to <= from
    }

    static func dollars(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD"))
    }

    static func describe(_ plan: Plan) -> String {
        ([plan.summary] + plan.tasks.map { "• \($0.title) (\($0.role)\($0.count > 1 ? " ×\($0.count)" : ""))" }).joined(separator: "\n")
    }

    func race<Value: Sendable>(stepId: String, timeoutMinutes: Int?, _ operation: @escaping @MainActor () async throws -> Value) async -> Result<Value, any Error> {
        let race = StepRace<Value>()
        let limit = timeoutMinutes.flatMap { $0 > 0 ? minute * $0 : nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.continuation = continuation
                race.work = Task { @MainActor in
                    do {
                        race.settle(.success(try await operation()))
                    } catch {
                        race.settle(.failure(error))
                    }
                }
                if let limit, let minutes = timeoutMinutes {
                    race.timer = Task { @MainActor in
                        try? await Task.sleep(for: limit)
                        guard !Task.isCancelled else { return }
                        race.work?.cancel()
                        race.settle(.failure(RunEngineError.timedOut(step: stepId, minutes: minutes)))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                race.work?.cancel()
                race.settle(.failure(CancellationError()))
            }
        }
    }
}

@MainActor
final class StepRace<Value: Sendable> {
    var continuation: CheckedContinuation<Result<Value, any Error>, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func settle(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: result)
    }
}
