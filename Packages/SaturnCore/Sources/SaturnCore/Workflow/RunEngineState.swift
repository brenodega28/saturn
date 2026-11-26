import Foundation
import Yams

public enum HoldReason: String, Sendable, Hashable, Codable, CaseIterable {
    case planApproval = "plan_approval"
    case approval
    case loopLimit = "loop_limit"
    case stepFailed = "step_failed"
    case timedOut = "timed_out"
    case gates

    public var requestKind: ChatRequestKind {
        switch self {
        case .planApproval: .planApproval
        case .approval: .approval
        case .loopLimit: .loopLimit
        case .stepFailed, .timedOut: .failure
        case .gates: .gate
        }
    }

    public var leadCanFix: Bool { [.stepFailed, .timedOut, .loopLimit].contains(self) }

    public var leadActions: [HoldAction] {
        switch self {
        case .stepFailed, .timedOut: [.retry, .fail]
        case .loopLimit: [.continue, .fail]
        case .planApproval, .approval, .gates: []
        }
    }
}

public enum HoldHandler: String, Sendable, Hashable, Codable {
    case lead
    case user
}

public enum HoldAction: String, Sendable, Hashable, CaseIterable {
    case retry
    case `continue`
    case fail
}

public struct RunHold: Sendable, Hashable, Codable {
    public var reason: HoldReason
    public var stepId: String
    public var runStepId: Int64?
    public var requestId: Int64?
    public var outcome: String?
    public var message: String
    public var body: String?
    public var handledBy: HoldHandler

    public init(
        reason: HoldReason, stepId: String, runStepId: Int64? = nil, requestId: Int64? = nil, outcome: String? = nil, message: String,
        body: String? = nil, handledBy: HoldHandler = .user
    ) {
        self.reason = reason
        self.stepId = stepId
        self.runStepId = runStepId
        self.requestId = requestId
        self.outcome = outcome
        self.message = message
        self.body = body
        self.handledBy = handledBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reason = try container.decode(HoldReason.self, forKey: .reason)
        self.stepId = try container.decode(String.self, forKey: .stepId)
        self.runStepId = try container.decodeIfPresent(Int64.self, forKey: .runStepId)
        self.requestId = try container.decodeIfPresent(Int64.self, forKey: .requestId)
        self.outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        self.message = try container.decode(String.self, forKey: .message)
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
        self.handledBy = try container.decodeIfPresent(HoldHandler.self, forKey: .handledBy) ?? .user
    }

    public var isLeadFixing: Bool { handledBy == .lead }

    public var leadFixingTitle: String? { isLeadFixing ? "Lead is fixing: \(message)" : nil }
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
    public var reviewNotes: [String]
    public var leadAttempts: [String: Int]

    public init(
        cursor: RunCursor? = nil, hold: RunHold? = nil, loopCounts: [String: Int] = [:], extraLoops: [String: Int] = [:],
        feedback: Feedback? = nil, reviewNotes: [String] = [], leadAttempts: [String: Int] = [:]
    ) {
        self.reviewNotes = reviewNotes
        self.leadAttempts = leadAttempts
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
        self.reviewNotes = try container.decodeIfPresent([String].self, forKey: .reviewNotes) ?? []
        self.leadAttempts = try container.decodeIfPresent([String: Int].self, forKey: .leadAttempts) ?? [:]
    }

    public static let leadAttemptLimit = 2

    static func loopKey(from stepId: String, outcome: String) -> String { "\(stepId)->\(outcome)" }
}

extension Run {
    public var snapshotWorkflow: WorkflowDefinition? {
        try? YAMLDecoder().decode(WorkflowDefinition.self, from: workflowSnapshot)
    }
}

extension RunHold {
    public func isChecksExhausted(in workflow: WorkflowDefinition?) -> Bool {
        reason == .stepFailed && !isLeadFixing && workflow?.step(stepId)?.type == .check
    }
}
