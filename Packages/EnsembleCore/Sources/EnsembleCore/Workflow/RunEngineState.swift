import Foundation

public enum HoldReason: String, Sendable, Hashable, Codable, CaseIterable {
    case planApproval = "plan_approval"
    case approval
    case loopLimit = "loop_limit"
    case stepBudget = "step_budget"
    case runBudget = "run_budget"
    case stepFailed = "step_failed"
    case timedOut = "timed_out"

    public var inboxKind: InboxKind {
        switch self {
        case .planApproval: .planApproval
        case .approval: .approval
        case .loopLimit: .loopLimit
        case .stepBudget, .runBudget: .budget
        case .stepFailed, .timedOut: .failure
        }
    }
}

public struct RunHold: Sendable, Hashable, Codable {
    public var reason: HoldReason
    public var stepId: String
    public var runStepId: Int64?
    public var inboxItemId: Int64?
    public var outcome: String?
    public var message: String

    public init(reason: HoldReason, stepId: String, runStepId: Int64? = nil, inboxItemId: Int64? = nil, outcome: String? = nil, message: String) {
        self.reason = reason
        self.stepId = stepId
        self.runStepId = runStepId
        self.inboxItemId = inboxItemId
        self.outcome = outcome
        self.message = message
    }
}

public enum StepStart: Sendable, Hashable, Codable {
    case fresh
    case retry(previousRunStepID: Int64)
    case resume(interruptedRunStepID: Int64)

    public var previousRunStepID: Int64? {
        switch self {
        case .fresh: nil
        case .retry(let id), .resume(let id): id
        }
    }
}

public struct RunCursor: Sendable, Hashable, Codable {
    public var stepId: String
    public var iteration: Int
    public var attempt: Int
    public var start: StepStart

    public init(stepId: String, iteration: Int, attempt: Int = 1, start: StepStart = .fresh) {
        self.stepId = stepId
        self.iteration = iteration
        self.attempt = attempt
        self.start = start
    }
}

public struct RunEngineState: Sendable, Hashable, Codable {
    public var cursor: RunCursor?
    public var hold: RunHold?
    public var loopCounts: [String: Int]
    public var extraLoops: [String: Int]
    public var feedback: Feedback?

    public init(
        cursor: RunCursor? = nil, hold: RunHold? = nil, loopCounts: [String: Int] = [:], extraLoops: [String: Int] = [:],
        feedback: Feedback? = nil
    ) {
        self.cursor = cursor
        self.hold = hold
        self.loopCounts = loopCounts
        self.extraLoops = extraLoops
        self.feedback = feedback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cursor = try container.decodeIfPresent(RunCursor.self, forKey: .cursor)
        self.hold = try container.decodeIfPresent(RunHold.self, forKey: .hold)
        self.loopCounts = try container.decodeIfPresent([String: Int].self, forKey: .loopCounts) ?? [:]
        self.extraLoops = try container.decodeIfPresent([String: Int].self, forKey: .extraLoops) ?? [:]
        self.feedback = try container.decodeIfPresent(Feedback.self, forKey: .feedback)
    }

    static func loopKey(from stepId: String, outcome: String) -> String { "\(stepId)->\(outcome)" }
}
