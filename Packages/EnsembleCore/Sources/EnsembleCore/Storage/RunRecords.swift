import Foundation
import GRDB

public struct GitHubMapping: Sendable, Hashable, Codable, Identifiable {
    public var label: String
    public var workflow: String
    public var autoStart: Bool

    public var id: String { label }

    public init(label: String, workflow: String, autoStart: Bool = false) {
        self.label = label
        self.workflow = workflow
        self.autoStart = autoStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        self.workflow = try container.decode(String.self, forKey: .workflow)
        self.autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

public struct ProjectSettings: Sendable, Hashable, Codable {
    public var maxConcurrentAgents: Int
    public var githubRepository: String?
    public var githubMappings: [GitHubMapping]
    public var githubPollMinutes: Int
    public var setupScript: String
    public var basePort: Int?
    public var idleCleanupMinutes: Int
    public var setupTimeoutMinutes: Int
    public var monthlyBudgetUSD: Double?
    public var budgetOverrideMonth: String?
    public var weeklyBudgetUSD: Double?
    public var budgetOverrideWeek: String?
    public var reviewCapacity: Int

    public init(
        maxConcurrentAgents: Int = 4,
        githubRepository: String? = nil,
        githubMappings: [GitHubMapping] = [],
        githubPollMinutes: Int = 5,
        setupScript: String = "",
        basePort: Int? = nil,
        idleCleanupMinutes: Int = 10,
        setupTimeoutMinutes: Int = 10,
        monthlyBudgetUSD: Double? = nil,
        budgetOverrideMonth: String? = nil,
        weeklyBudgetUSD: Double? = nil,
        budgetOverrideWeek: String? = nil,
        reviewCapacity: Int = 3
    ) {
        self.weeklyBudgetUSD = weeklyBudgetUSD
        self.budgetOverrideWeek = budgetOverrideWeek
        self.reviewCapacity = reviewCapacity
        self.setupTimeoutMinutes = setupTimeoutMinutes
        self.maxConcurrentAgents = maxConcurrentAgents
        self.githubRepository = githubRepository
        self.githubMappings = githubMappings
        self.githubPollMinutes = githubPollMinutes
        self.setupScript = setupScript
        self.basePort = basePort
        self.idleCleanupMinutes = idleCleanupMinutes
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.budgetOverrideMonth = budgetOverrideMonth
    }

    public init(from decoder: Decoder) throws {
        let defaults = ProjectSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxConcurrentAgents = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentAgents) ?? defaults.maxConcurrentAgents
        self.githubRepository = try container.decodeIfPresent(String.self, forKey: .githubRepository)
        self.githubMappings = try container.decodeIfPresent([GitHubMapping].self, forKey: .githubMappings) ?? []
        self.githubPollMinutes = try container.decodeIfPresent(Int.self, forKey: .githubPollMinutes) ?? defaults.githubPollMinutes
        self.setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        self.basePort = try container.decodeIfPresent(Int.self, forKey: .basePort)
        self.idleCleanupMinutes = try container.decodeIfPresent(Int.self, forKey: .idleCleanupMinutes) ?? defaults.idleCleanupMinutes
        self.setupTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .setupTimeoutMinutes) ?? defaults.setupTimeoutMinutes
        self.monthlyBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD)
        self.budgetOverrideMonth = try container.decodeIfPresent(String.self, forKey: .budgetOverrideMonth)
        self.reviewCapacity = try container.decodeIfPresent(Int.self, forKey: .reviewCapacity) ?? defaults.reviewCapacity
        self.weeklyBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .weeklyBudgetUSD)
        self.budgetOverrideWeek = try container.decodeIfPresent(String.self, forKey: .budgetOverrideWeek)
    }
}

public enum RunStepStatus: String, Codable, Sendable, CaseIterable {
    case running
    case waitingOnYou
    case succeeded
    case failed
    case cancelled
    case interrupted
}

public struct RunStep: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "runStep"

    public var id: Int64?
    public var runId: Int64
    public var stepId: String
    public var iteration: Int
    public var status: RunStepStatus
    public var outcome: String?
    public var output: String?
    public var input: String?
    public var costUSD: Double
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: Int64? = nil, runId: Int64, stepId: String, iteration: Int = 1, status: RunStepStatus,
        outcome: String? = nil, output: String? = nil, input: String? = nil, costUSD: Double = 0,
        startedAt: Date, endedAt: Date? = nil
    ) {
        self.id = id
        self.runId = runId
        self.stepId = stepId
        self.iteration = iteration
        self.status = status
        self.outcome = outcome
        self.output = output
        self.input = input
        self.costUSD = costUSD
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let runId = Column(CodingKeys.runId)
        public static let stepId = Column(CodingKeys.stepId)
        public static let iteration = Column(CodingKeys.iteration)
        public static let status = Column(CodingKeys.status)
        public static let startedAt = Column(CodingKeys.startedAt)
    }
}

public enum PinStatus: String, Codable, Sendable, CaseIterable {
    case open
    case approved
    case changeRequested = "change_requested"
}

public enum PinSide: String, Codable, Sendable, CaseIterable {
    case new
    case old
}

public struct Pin: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pin"

    public var id: Int64?
    public var runId: Int64
    public var agentId: Int64?
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var side: PinSide
    public var byUser: Bool
    public var title: String
    public var tags: [String]
    public var explanation: String
    public var status: PinStatus
    public var response: String?
    public var confidence: Double?
    public var category: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, runId: Int64, agentId: Int64?, file: String, startLine: Int, endLine: Int,
        side: PinSide = .new, byUser: Bool = false,
        title: String, tags: [String] = [], explanation: String, status: PinStatus = .open,
        response: String? = nil, confidence: Double? = nil, category: String? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.confidence = confidence
        self.category = category
        self.side = side
        self.byUser = byUser
        self.id = id
        self.runId = runId
        self.agentId = agentId
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.title = title
        self.tags = tags
        self.explanation = explanation
        self.status = status
        self.response = response
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let runId = Column(CodingKeys.runId)
        public static let status = Column(CodingKeys.status)
    }
}

public enum EvidenceKind: String, Codable, Sendable, CaseIterable {
    case screenshot
    case recording
    case benchmark
    case log
}

public struct Evidence: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "evidence"

    public var id: Int64?
    public var runId: Int64
    public var agentId: Int64?
    public var kind: EvidenceKind
    public var title: String
    public var file: String
    public var note: String
    public var createdAt: Date

    public init(id: Int64? = nil, runId: Int64, agentId: Int64?, kind: EvidenceKind, title: String, file: String, note: String = "", createdAt: Date) {
        self.id = id
        self.runId = runId
        self.agentId = agentId
        self.kind = kind
        self.title = title
        self.file = file
        self.note = note
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var url: URL { URL(filePath: file) }
}

public enum InboxKind: String, Codable, Sendable, CaseIterable {
    case question
    case planApproval = "plan_approval"
    case pinReview = "pin_review"
    case approval
    case failure
    case notice
    case loopLimit = "loop_limit"
    case budget
    case gate
    case permission
}

public enum InboxStatus: String, Codable, Sendable, CaseIterable {
    case open
    case resolved
    case dismissed
}

public struct InboxItem: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "inboxItem"

    public var id: Int64?
    public var projectId: Int64
    public var runId: Int64?
    public var agentId: Int64?
    public var kind: InboxKind
    public var title: String
    public var body: String
    public var status: InboxStatus
    public var response: String?
    public var questions: [HumanQuestion]?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: Int64? = nil, projectId: Int64, runId: Int64? = nil, agentId: Int64? = nil, kind: InboxKind,
        title: String, body: String = "", status: InboxStatus = .open, response: String? = nil,
        questions: [HumanQuestion]? = nil, createdAt: Date, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.runId = runId
        self.agentId = agentId
        self.kind = kind
        self.title = title
        self.body = body
        self.status = status
        self.response = response
        self.questions = questions
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let projectId = Column(CodingKeys.projectId)
        public static let runId = Column(CodingKeys.runId)
        public static let status = Column(CodingKeys.status)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}

extension ProjectTask {
    public enum Columns {
        public static let projectId = Column("projectId")
        public static let status = Column("status")
        public static let source = Column("source")
        public static let externalNumber = Column("externalNumber")
        public static let createdAt = Column("createdAt")
    }
}

extension Run {
    public enum Columns {
        public static let projectId = Column("projectId")
        public static let taskId = Column("taskId")
        public static let status = Column("status")
        public static let startedAt = Column("startedAt")
    }

    public var isActive: Bool {
        [.pending, .running, .waitingOnYou, .paused, .interrupted].contains(status)
    }
}
