#if DEBUG
import Foundation

extension RunEngine {
    func traceRunStarted(_ run: Run, workflow: WorkflowDefinition) {
        guard let trace = debugTrace, let runId = run.id else { return }
        var fields: DebugFields = [
            "workflow": JSONValue(workflow.id),
            "workflowVersion": JSONValue(run.workflowVersion),
            "title": JSONValue(run.title),
            "taskId": JSONValue(run.taskId),
            "projectId": JSONValue(run.projectId),
            "budgetUSD": JSONValue(run.budgetUSD),
            "endAction": JSONValue(run.endAction),
            "steps": JSONValue(workflow.steps.map(\.id)),
            "firstStep": JSONValue(run.currentStep),
        ]
        if let brief = run.brief {
            fields["briefHash"] = JSONValue(trace.storePrompt(brief))
            fields["briefPreview"] = JSONValue(DebugText.preview(brief, limit: DebugTrace.previewLength))
        }
        trace.runEvent("run_started", runId: runId, title: run.title, fields: fields, at: clock())
    }

    func traceStepStarted(_ loaded: LoadedRun, row: RunStep, cursor: RunCursor) {
        guard let trace = debugTrace else { return }
        let step = loaded.workflow.step(row.stepId)
        var fields: DebugFields = [
            "kind": JSONValue(step?.type.rawValue ?? "end"),
            "role": JSONValue(step?.agent?.rawValue),
            "iteration": JSONValue(row.iteration),
            "attempt": JSONValue(cursor.attempt),
            "start": JSONValue(Self.describe(cursor.start)),
            "status": JSONValue(row.status.rawValue),
        ]
        if let input = row.input { embed(input, as: "input", into: &fields, trace: trace) }
        trace.runEvent("step_started", runId: row.runId, title: loaded.run.title, stepId: row.stepId, runStepId: row.id, fields: fields, at: clock())
    }

    func traceCommitted(_ loaded: LoadedRun, steps: [RunStep]) {
        guard let trace = debugTrace, let runId = loaded.run.id else { return }
        for step in steps where step.endedAt != nil && [.succeeded, .failed, .cancelled].contains(step.status) {
            var fields: DebugFields = [
                "status": JSONValue(step.status.rawValue),
                "outcome": JSONValue(step.outcome),
                "costUSD": JSONValue(step.costUSD),
                "iteration": JSONValue(step.iteration),
                "durationMS": JSONValue(Int(((step.endedAt ?? step.startedAt).timeIntervalSince(step.startedAt)) * 1000)),
            ]
            if let output = step.output {
                fields["outputPreview"] = JSONValue(DebugText.preview(decodeOutput(output).summary ?? output, limit: DebugTrace.previewLength))
                embed(output, as: "output", into: &fields, trace: trace)
            }
            trace.runEvent("step_finished", runId: runId, title: loaded.run.title, stepId: step.stepId, runStepId: step.id, fields: fields, at: clock())
        }
        guard !loaded.run.isActive else { return }
        let rows = (try? database.runSteps(runId: runId)) ?? []
        let iterations = Dictionary(rows.map { ($0.stepId, $0.iteration) }, uniquingKeysWith: max)
        let attempts = Dictionary(rows.map { ($0.stepId, 1) }, uniquingKeysWith: +)
        let ended = loaded.run.endedAt ?? clock()
        trace.runEvent("run_finished", runId: runId, title: loaded.run.title, fields: [
            "status": JSONValue(loaded.run.status.rawValue),
            "totalCostUSD": JSONValue(loaded.run.costUSD),
            "durationMS": JSONValue(Int(ended.timeIntervalSince(loaded.run.startedAt) * 1000)),
            "outcome": JSONValue(loaded.run.outcome),
            "lastError": JSONValue(loaded.run.lastError),
            "pushedAt": JSONValue(loaded.run.pushedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "deliveryBranch": JSONValue(loaded.run.deliveryBranch),
            "iterationsPerStep": .object(iterations.mapValues { JSONValue($0) }),
            "rowsPerStep": .object(attempts.mapValues { JSONValue($0) }),
        ], at: clock())
    }

    func traceCondition(_ loaded: LoadedRun, step: WorkflowStep, runStepId: Int64, facts: ConditionFacts, matched: Bool) {
        debugTrace?.runEvent("condition_evaluated", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: step.id, runStepId: runStepId, fields: [
            "expression": step.condition.flatMap { JSONValue(encoding: $0) } ?? .null,
            "labels": JSONValue(facts.labels),
            "diff": facts.diff.flatMap { JSONValue(encoding: $0) } ?? .null,
            "outcomes": .object(facts.outcomes.mapValues { JSONValue($0) }),
            "result": JSONValue(matched),
        ], at: clock())
    }

    func traceRouted(_ loaded: LoadedRun, from step: WorkflowStep, to target: String, outcome: String, loopCount: Int, maxLoops: Int?, iteration: Int) {
        debugTrace?.runEvent("routed", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: step.id, fields: [
            "from": JSONValue(step.id),
            "to": JSONValue(target),
            "outcome": JSONValue(outcome),
            "isLoopBack": JSONValue(Self.isLoopBack(from: step.id, to: target, in: loaded.workflow)),
            "loopCount": JSONValue(loopCount),
            "maxLoops": maxLoops.map { JSONValue($0) } ?? .null,
            "nextIteration": JSONValue(iteration),
            "feedback": loaded.state.feedback.flatMap { JSONValue(encoding: $0) } ?? .null,
        ], at: clock())
    }

    func traceHold(_ loaded: LoadedRun, title: String, body: String) {
        guard let trace = debugTrace, let hold = loaded.state.hold else { return }
        trace.runEvent("hold", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: hold.stepId, runStepId: hold.runStepId, fields: [
            "reason": JSONValue(hold.reason.rawValue),
            "requestKind": JSONValue(hold.reason.requestKind.rawValue),
            "requestId": JSONValue(hold.requestId),
            "outcome": JSONValue(hold.outcome),
            "title": JSONValue(title),
            "body": JSONValue(body),
        ], at: clock())
        guard [.stepBudget, .runBudget].contains(hold.reason) else { return }
        trace.runEvent("budget", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: hold.stepId, runStepId: hold.runStepId, fields: [
            "event": JSONValue("exceeded"),
            "reason": JSONValue(hold.reason.rawValue),
            "runCostUSD": JSONValue(loaded.run.costUSD),
            "runBudgetUSD": JSONValue(loaded.run.budgetUSD),
        ], at: clock())
    }

    func traceChatRequest(_ loaded: LoadedRun, stepId: String, kind: ChatRequestKind, title: String, body: String) {
        debugTrace?.runEvent("chat_request", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: stepId, fields: [
            "kind": JSONValue(kind.rawValue),
            "title": JSONValue(title),
            "body": JSONValue(body),
        ], at: clock())
    }

    func traceReleased(_ loaded: LoadedRun, response: String?, decision: String?) {
        guard let trace = debugTrace, let hold = loaded.state.hold else { return }
        let now = clock()
        var fields: DebugFields = [
            "reason": JSONValue(hold.reason.rawValue),
            "decision": JSONValue(decision ?? response),
            "response": JSONValue(response),
            "requestId": JSONValue(hold.requestId),
        ]
        if let id = hold.requestId, let item = try? database.chatRequest(id: id) {
            fields["waitMS"] = JSONValue(Int(now.timeIntervalSince(item.createdAt) * 1000))
        }
        trace.runEvent("hold_resolved", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: hold.stepId, runStepId: hold.runStepId, fields: fields, at: now)
    }

    func traceBudgetDecision(_ loaded: LoadedRun, proceed: Bool, newBudget: Double?) {
        debugTrace?.runEvent("budget", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: loaded.state.hold?.stepId, fields: [
            "event": JSONValue("decision"),
            "proceed": JSONValue(proceed),
            "previousBudgetUSD": JSONValue(loaded.run.budgetUSD),
            "newBudgetUSD": JSONValue(newBudget),
            "runCostUSD": JSONValue(loaded.run.costUSD),
        ], at: clock())
    }

    func traceStepFailed(_ loaded: LoadedRun, stepId: String, runStepId: Int64, error: any Error, onFailure: FailureAction) {
        debugTrace?.runEvent("step_failed", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: stepId, runStepId: runStepId, fields: [
            "error": JSONValue(error.localizedDescription),
            "errorType": JSONValue(String(describing: type(of: error))),
            "onFailure": JSONValue(onFailure.rawValue),
            "attempt": JSONValue(loaded.state.cursor?.attempt ?? 1),
        ], at: clock())
    }

    func traceFailureAction(_ loaded: LoadedRun, stepId: String, action: String) {
        debugTrace?.runEvent("failure_action", runId: loaded.run.id ?? -1, title: loaded.run.title, stepId: stepId, fields: [
            "action": JSONValue(action),
        ], at: clock())
    }

    func traceControl(_ run: Run, action: String) {
        guard let runId = run.id else { return }
        debugTrace?.runEvent("run_control", runId: runId, title: run.title, stepId: run.currentStep, fields: [
            "action": JSONValue(action),
            "status": JSONValue(run.status.rawValue),
        ], at: clock())
    }

    private func embed(_ text: String, as key: String, into fields: inout DebugFields, trace: DebugTrace) {
        if text.utf8.count <= DebugTrace.inlineLimit, let json = JSONValue.parse(text) {
            fields[key] = json
        } else {
            fields["\(key)Hash"] = JSONValue(trace.storePrompt(text))
            fields["\(key)Length"] = JSONValue(text.count)
        }
    }

    private static func describe(_ start: StepStart) -> String {
        switch start {
        case .fresh: "fresh"
        case .retry: "retry"
        case .resume: "resume"
        }
    }
}
#endif
