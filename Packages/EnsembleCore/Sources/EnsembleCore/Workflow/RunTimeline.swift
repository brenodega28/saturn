import Foundation

public struct RunTimeline: Sendable, Hashable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var stepId: String
        public var title: String
        public var type: StepType?
        public var iteration: Int
        public var status: RunStepStatus
        public var outcome: String?
        public var summary: String?
        public var issues: [ReviewIssue]
        public var plan: Plan?
        public var costUSD: Double
        public var startedAt: Date
        public var endedAt: Date?

        public var outcomeTitle: String? { outcome.map(RunTimeline.title(forOutcome:)) }
    }

    public enum StageState: String, Sendable, Hashable {
        case done
        case current
        case waiting
        case failed
        case upcoming
    }

    public struct Stage: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var state: StageState
    }

    public var entries: [Entry]
    public var stages: [Stage]
    public var currentStepTitle: String?
    public var pendingPlan: Plan?
    public var questions: [InboxItem]
    public var holdItem: InboxItem?

    public init(run: Run, workflow: WorkflowDefinition, steps: [RunStep], hold: RunHold?, inbox: [InboxItem] = []) {
        self.entries = steps.compactMap { step in
            guard let id = step.id else { return nil }
            let output = Self.decodeOutput(step.output)
            return Entry(
                id: id, stepId: step.stepId, title: Self.title(ofStep: step.stepId, in: workflow),
                type: workflow.step(step.stepId)?.type, iteration: step.iteration, status: step.status,
                outcome: step.outcome, summary: output.verdict?.summary ?? output.summary,
                issues: output.verdict?.issues ?? [], plan: output.plan, costUSD: step.costUSD, startedAt: step.startedAt, endedAt: step.endedAt
            )
        }
        self.stages = Self.stages(run: run, workflow: workflow, steps: steps, hold: hold)
        self.currentStepTitle = run.currentStep.map { Self.title(ofStep: $0, in: workflow) }
        if hold?.reason == .planApproval, let planStepID = hold?.runStepId {
            self.pendingPlan = steps.first { $0.id == planStepID }.flatMap { Self.decodeOutput($0.output).plan }
        } else {
            self.pendingPlan = nil
        }
        self.questions = inbox.filter { $0.kind == .question && $0.status == .open }
        self.holdItem = hold?.inboxItemId.flatMap { id in inbox.first { $0.id == id } }
    }

    public var approvedPlan: Plan? {
        entries.last { $0.status == .succeeded && $0.plan != nil }?.plan
    }

    public static func title(ofStep stepId: String, in workflow: WorkflowDefinition) -> String {
        if stepId == WorkflowDefinition.endStepID { return "Finish" }
        return workflow.step(stepId)?.displayTitle ?? stepId
    }

    public static func title(forOutcome outcome: String) -> String {
        let words = outcome.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func decodeOutput(_ text: String?) -> StepOutput {
        text.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) } ?? StepOutput()
    }

    static func stages(run: Run, workflow: WorkflowDefinition, steps: [RunStep], hold: RunHold?) -> [Stage] {
        let ids = workflow.steps.map(\.id) + [WorkflowDefinition.endStepID]
        let succeeded = Set(steps.filter { $0.status == .succeeded }.map(\.stepId))
        return ids.map { id in
            let state: StageState
            if run.status == .succeeded {
                state = succeeded.contains(id) || id == WorkflowDefinition.endStepID ? .done : .upcoming
            } else if id == run.currentStep {
                switch run.status {
                case .failed: state = .failed
                case .waitingOnYou: state = hold.map { [.stepFailed, .timedOut].contains($0.reason) } == true ? .failed : .waiting
                case .cancelled: state = .upcoming
                default: state = .current
                }
            } else {
                state = succeeded.contains(id) ? .done : .upcoming
            }
            return Stage(id: id, title: title(ofStep: id, in: workflow), state: state)
        }
    }
}

extension AppDatabase {
    public func timeline(for run: Run, workflow: WorkflowDefinition) throws -> RunTimeline {
        guard let runID = run.id else { throw RunEngineError.runNotFound }
        return RunTimeline(
            run: run, workflow: workflow, steps: try runSteps(runId: runID),
            hold: try engineState(runId: runID).hold, inbox: try inboxItems(runId: runID)
        )
    }
}
