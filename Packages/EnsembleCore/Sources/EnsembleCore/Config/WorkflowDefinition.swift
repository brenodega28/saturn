import Foundation

public struct WorkflowDefinition: Sendable, Hashable, Identifiable, Codable {
    public static let endStepID = "end"

    public var id: String
    public var name: String
    public var version: Int
    public var description: String
    public var trigger: WorkflowTrigger
    public var budget: Double?
    public var steps: [WorkflowStep]
    public var end: WorkflowEnd

    public init(
        id: String,
        name: String,
        version: Int = 1,
        description: String = "",
        trigger: WorkflowTrigger = WorkflowTrigger(),
        budget: Double? = nil,
        steps: [WorkflowStep],
        end: WorkflowEnd = WorkflowEnd()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.trigger = trigger
        self.budget = budget
        self.steps = steps
        self.end = end
    }

    enum CodingKeys: String, CodingKey {
        case name, version, description, trigger, budget, steps, end
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = ""
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.trigger = try container.decodeIfPresent(WorkflowTrigger.self, forKey: .trigger) ?? WorkflowTrigger()
        self.budget = try container.decodeIfPresent(Double.self, forKey: .budget)
        self.steps = try container.decode([WorkflowStep].self, forKey: .steps)
        self.end = try container.decodeIfPresent(WorkflowEnd.self, forKey: .end) ?? WorkflowEnd()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        if !description.isEmpty { try container.encode(description, forKey: .description) }
        try container.encode(trigger, forKey: .trigger)
        try container.encodeNumber(budget, forKey: .budget)
        try container.encode(steps, forKey: .steps)
        try container.encode(end, forKey: .end)
    }

    public var firstStep: WorkflowStep? { steps.first }

    public func step(_ id: String) -> WorkflowStep? {
        steps.first { $0.id == id }
    }

    public var displayName: String { "\(name) v\(version)" }
}

public struct WorkflowTrigger: Sendable, Hashable, Codable {
    public var sources: [TaskSource]
    public var labels: [String]

    public init(sources: [TaskSource] = [.chat], labels: [String] = []) {
        self.sources = sources
        self.labels = labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([TaskSource].self, forKey: .sources) ?? [.chat]
        self.labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

public enum StepType: String, Sendable, Hashable, Codable, CaseIterable {
    case agent
    case spawn
    case condition
    case approval
    case notify
    case check
    case gates
}

public enum FailureAction: String, Sendable, Hashable, Codable, CaseIterable {
    case retry
    case ask
    case fail
}

public struct WorkflowRoute: Sendable, Hashable, Codable {
    public var to: String
    public var maxLoops: Int?

    public init(to: String, maxLoops: Int? = nil) {
        self.to = to
        self.maxLoops = maxLoops
    }

    enum CodingKeys: String, CodingKey {
        case to
        case maxLoops = "max_loops"
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let target = try? single.decode(String.self) {
            self.init(to: target)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            to: try container.decode(String.self, forKey: .to),
            maxLoops: try container.decodeIfPresent(Int.self, forKey: .maxLoops)
        )
    }

    public func encode(to encoder: Encoder) throws {
        if let maxLoops {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(to, forKey: .to)
            try container.encode(maxLoops, forKey: .maxLoops)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(to)
        }
    }
}

public struct StepCondition: Sendable, Hashable, Codable {
    public var labelsAny: [String]?
    public var pathsAny: [String]?
    public var diffLinesOver: Int?
    public var outcomeOf: String?
    public var equals: String?

    public init(labelsAny: [String]? = nil, pathsAny: [String]? = nil, diffLinesOver: Int? = nil, outcomeOf: String? = nil, equals: String? = nil) {
        self.labelsAny = labelsAny
        self.pathsAny = pathsAny
        self.diffLinesOver = diffLinesOver
        self.outcomeOf = outcomeOf
        self.equals = equals
    }

    enum CodingKeys: String, CodingKey {
        case labelsAny = "labels_any"
        case pathsAny = "paths_any"
        case diffLinesOver = "diff_lines_over"
        case outcomeOf = "outcome_of"
        case equals
    }
}

public struct WorkflowStep: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var type: StepType
    public var title: String?
    public var agent: AgentKind?
    public var model: String?
    public var legacyRole: String?
    public var instructions: String
    public var maxAgents: Int?
    public var checks: [String]?
    public var maxRounds: Int?
    public var testFirst: Bool
    public var reusePinned: Bool
    public var remindDaily: Bool
    public var condition: StepCondition?
    public var message: String?
    public var timeoutMinutes: Int?
    public var budget: Double?
    public var onFailure: FailureAction
    public var next: String?
    public var routes: [String: WorkflowRoute]
    public var position: CanvasPosition?

    public init(
        id: String,
        type: StepType,
        title: String? = nil,
        agent: AgentKind? = nil,
        model: String? = nil,
        instructions: String = "",
        maxAgents: Int? = nil,
        checks: [String]? = nil,
        maxRounds: Int? = nil,
        testFirst: Bool = false,
        reusePinned: Bool = false,
        remindDaily: Bool = false,
        condition: StepCondition? = nil,
        message: String? = nil,
        timeoutMinutes: Int? = nil,
        budget: Double? = nil,
        onFailure: FailureAction = .ask,
        next: String? = nil,
        routes: [String: WorkflowRoute] = [:],
        position: CanvasPosition? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.agent = agent
        self.model = model
        self.instructions = instructions
        self.maxAgents = maxAgents
        self.checks = checks
        self.maxRounds = maxRounds
        self.testFirst = testFirst
        self.reusePinned = reusePinned
        self.remindDaily = remindDaily
        self.condition = condition
        self.message = message
        self.timeoutMinutes = timeoutMinutes
        self.budget = budget
        self.onFailure = onFailure
        self.next = next
        self.routes = routes
        self.position = position
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, agent, model, role, instructions, checks, condition, message, budget, next, routes, position
        case maxAgents = "max_agents"
        case maxRounds = "max_rounds"
        case testFirst = "test_first"
        case reusePinned = "reuse_pinned"
        case remindDaily = "remind_daily"
        case timeoutMinutes = "timeout_minutes"
        case onFailure = "on_failure"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(StepType.self, forKey: .type)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.legacyRole = try container.decodeIfPresent(String.self, forKey: .role)
        self.agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent) ?? legacyRole.map(AgentKind.guessing(roleID:))
        self.instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        self.maxAgents = try container.decodeIfPresent(Int.self, forKey: .maxAgents)
        self.checks = try container.decodeIfPresent([String].self, forKey: .checks)
        self.maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds)
        self.testFirst = try container.decodeIfPresent(Bool.self, forKey: .testFirst) ?? false
        self.reusePinned = try container.decodeIfPresent(Bool.self, forKey: .reusePinned) ?? false
        self.remindDaily = try container.decodeIfPresent(Bool.self, forKey: .remindDaily) ?? false
        self.condition = try container.decodeIfPresent(StepCondition.self, forKey: .condition)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.timeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .timeoutMinutes)
        self.budget = try container.decodeIfPresent(Double.self, forKey: .budget)
        self.onFailure = try container.decodeIfPresent(FailureAction.self, forKey: .onFailure) ?? .ask
        self.next = try container.decodeIfPresent(String.self, forKey: .next)
        self.routes = try container.decodeIfPresent([String: WorkflowRoute].self, forKey: .routes) ?? [:]
        self.position = try container.decodeIfPresent(CanvasPosition.self, forKey: .position)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(model, forKey: .model)
        if !instructions.isEmpty { try container.encode(instructions, forKey: .instructions) }
        try container.encodeIfPresent(maxAgents, forKey: .maxAgents)
        try container.encodeIfPresent(checks, forKey: .checks)
        try container.encodeIfPresent(maxRounds, forKey: .maxRounds)
        if testFirst { try container.encode(testFirst, forKey: .testFirst) }
        if reusePinned { try container.encode(reusePinned, forKey: .reusePinned) }
        if remindDaily { try container.encode(remindDaily, forKey: .remindDaily) }
        try container.encodeIfPresent(condition, forKey: .condition)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(timeoutMinutes, forKey: .timeoutMinutes)
        try container.encodeNumber(budget, forKey: .budget)
        if onFailure != .ask { try container.encode(onFailure, forKey: .onFailure) }
        try container.encodeIfPresent(next, forKey: .next)
        if !routes.isEmpty { try container.encode(routes, forKey: .routes) }
        try container.encodeIfPresent(position, forKey: .position)
    }

    public var displayTitle: String { title ?? id }

    public var targets: [String] {
        ([next].compactMap(\.self) + routes.values.map(\.to)).reduce(into: []) { result, target in
            if !result.contains(target) { result.append(target) }
        }
    }
}

public struct CanvasPosition: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    enum CodingKeys: String, CodingKey {
        case x, y
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNumber(x.rounded(), forKey: .x)
        try container.encodeNumber(y.rounded(), forKey: .y)
    }
}

public enum EndAction: String, Sendable, Hashable, Codable, CaseIterable {
    case pullRequest = "pull_request"
    case merge
    case push
    case leave
}

public struct WorkflowEnd: Sendable, Hashable, Codable {
    public var action: EndAction
    public var cleanUpWorktrees: Bool
    public var postSummary: Bool

    public init(action: EndAction = .pullRequest, cleanUpWorktrees: Bool = true, postSummary: Bool = true) {
        self.action = action
        self.cleanUpWorktrees = cleanUpWorktrees
        self.postSummary = postSummary
    }

    enum CodingKeys: String, CodingKey {
        case action
        case cleanUpWorktrees = "clean_up_worktrees"
        case postSummary = "post_summary"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decodeIfPresent(EndAction.self, forKey: .action) ?? .pullRequest
        self.cleanUpWorktrees = try container.decodeIfPresent(Bool.self, forKey: .cleanUpWorktrees) ?? true
        self.postSummary = try container.decodeIfPresent(Bool.self, forKey: .postSummary) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(cleanUpWorktrees, forKey: .cleanUpWorktrees)
        if !postSummary { try container.encode(postSummary, forKey: .postSummary) }
    }
}

public enum StepOutcome {
    public static let done = "done"
    public static let approved = "approved"
    public static let changesRequested = "changes_requested"
    public static let passed = "passed"
    public static let failed = "failed"
    public static let yes = "yes"
    public static let no = "no"
}
