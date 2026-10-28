import Foundation
import GRDB

public struct Project: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "project"

    public var id: Int64?
    public var name: String
    public var path: String
    public var isOpen: Bool
    public var createdAt: Date
    public var lastOpenedAt: Date
    public var settings: ProjectSettings

    public init(id: Int64? = nil, name: String, path: String, isOpen: Bool, createdAt: Date, lastOpenedAt: Date, settings: ProjectSettings = ProjectSettings()) {
        self.id = id
        self.name = name
        self.path = path
        self.isOpen = isOpen
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.settings = settings
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let path = Column(CodingKeys.path)
        public static let name = Column(CodingKeys.name)
        public static let isOpen = Column(CodingKeys.isOpen)
        public static let lastOpenedAt = Column(CodingKeys.lastOpenedAt)
    }
}

public enum TaskSource: String, Codable, Sendable, CaseIterable {
    case chat
    case github
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case incoming
    case running
    case waitingOnYou
    case done
    case failed
    case dismissed
}

public enum RequestCloseReason: String, Codable, Sendable, CaseIterable {
    case done
    case dropped

    public var title: String {
        switch self {
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }
}

public struct ProjectTask: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "task"

    public var id: Int64?
    public var projectId: Int64
    public var title: String
    public var body: String
    public var source: TaskSource
    public var sourceURL: String?
    public var workflow: String?
    public var status: TaskStatus
    public var externalNumber: Int?
    public var repository: String?
    public var labels: [String]
    public var closedAt: Date?
    public var closeReason: RequestCloseReason?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, projectId: Int64, title: String, body: String, source: TaskSource,
        sourceURL: String? = nil, workflow: String? = nil, status: TaskStatus, externalNumber: Int? = nil,
        repository: String? = nil, labels: [String] = [], closedAt: Date? = nil, closeReason: RequestCloseReason? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.closedAt = closedAt
        self.closeReason = closeReason
        self.externalNumber = externalNumber
        self.repository = repository
        self.labels = labels
        self.id = id
        self.projectId = projectId
        self.title = title
        self.body = body
        self.source = source
        self.sourceURL = sourceURL
        self.workflow = workflow
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isClosed: Bool { closedAt != nil }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum RunStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case waitingOnYou
    case paused
    case interrupted
    case succeeded
    case failed
    case cancelled
}

public struct Run: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "run"

    public var id: Int64?
    public var projectId: Int64
    public var taskId: Int64
    public var workflow: String
    public var workflowVersion: String?
    public var currentStep: String?
    public var status: RunStatus
    public var outcome: String?
    public var costUSD: Double
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var workflowSnapshot: String
    public var budgetUSD: Double?
    public var endAction: String?
    public var pullRequestURL: String?
    public var lastError: String?
    public var brief: String?
    public var deliveryBranch: String?
    public var baseBranch: String?
    public var mergedAt: Date?
    public var linesChanged: Int?
    public var filesChanged: Int?

    public init(
        id: Int64? = nil, projectId: Int64, taskId: Int64, workflow: String, workflowVersion: String? = nil,
        currentStep: String? = nil, status: RunStatus, outcome: String? = nil, costUSD: Double = 0,
        startedAt: Date, endedAt: Date? = nil, title: String = "", workflowSnapshot: String = "",
        budgetUSD: Double? = nil, endAction: String? = nil, pullRequestURL: String? = nil, lastError: String? = nil,
        brief: String? = nil, deliveryBranch: String? = nil, baseBranch: String? = nil, mergedAt: Date? = nil,
        linesChanged: Int? = nil, filesChanged: Int? = nil
    ) {
        self.linesChanged = linesChanged
        self.filesChanged = filesChanged
        self.brief = brief
        self.deliveryBranch = deliveryBranch
        self.baseBranch = baseBranch
        self.mergedAt = mergedAt
        self.title = title
        self.workflowSnapshot = workflowSnapshot
        self.budgetUSD = budgetUSD
        self.endAction = endAction
        self.pullRequestURL = pullRequestURL
        self.lastError = lastError
        self.id = id
        self.projectId = projectId
        self.taskId = taskId
        self.workflow = workflow
        self.workflowVersion = workflowVersion
        self.currentStep = currentStep
        self.status = status
        self.outcome = outcome
        self.costUSD = costUSD
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case needsInput
    case waiting
    case reviewing
    case paused
    case interrupted
    case stopped
    case takenOver
    case failed

    public var hasLiveProcess: Bool { self == .working }
}

public struct Agent: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "agent"

    public var id: Int64?
    public var projectId: Int64
    public var runId: Int64?
    public var role: String
    public var name: String
    public var step: String?
    public var worktreePath: String?
    public var branch: String?
    public var status: AgentStatus
    public var sessionId: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double
    public var isPinned: Bool
    public var model: String
    public var task: String
    public var baseBranch: String?
    public var processID: Int32?
    public var lastError: String?
    public var runStepId: Int64?
    public var readOnly: Bool
    public var planTaskId: String?
    public var port: Int?
    public var archivedAt: Date?
    public var taskId: Int64?
    public var spawnedById: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, projectId: Int64, runId: Int64? = nil, role: String, name: String, step: String? = nil,
        worktreePath: String? = nil, branch: String? = nil, status: AgentStatus, sessionId: String? = nil,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
        costUSD: Double = 0, isPinned: Bool = false, model: String = AgentModel.sonnet.rawValue, task: String = "",
        baseBranch: String? = nil, processID: Int32? = nil, lastError: String? = nil,
        runStepId: Int64? = nil, readOnly: Bool = false, planTaskId: String? = nil,
        port: Int? = nil, archivedAt: Date? = nil, taskId: Int64? = nil, spawnedById: Int64? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.taskId = taskId
        self.spawnedById = spawnedById
        self.port = port
        self.archivedAt = archivedAt
        self.runStepId = runStepId
        self.readOnly = readOnly
        self.planTaskId = planTaskId
        self.id = id
        self.projectId = projectId
        self.runId = runId
        self.role = role
        self.name = name
        self.step = step
        self.worktreePath = worktreePath
        self.branch = branch
        self.status = status
        self.sessionId = sessionId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.isPinned = isPinned
        self.model = model
        self.task = task
        self.baseBranch = baseBranch
        self.processID = processID
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    public var worktreeURL: URL? { worktreePath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let projectId = Column(CodingKeys.projectId)
        public static let runId = Column(CodingKeys.runId)
        public static let runStepId = Column(CodingKeys.runStepId)
        public static let status = Column(CodingKeys.status)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}

public struct UsageEntry: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "usage"

    public var id: Int64?
    public var projectId: Int64
    public var runId: Int64?
    public var agentId: Int64?
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double
    public var recordedAt: Date

    public init(
        id: Int64? = nil, projectId: Int64, runId: Int64? = nil, agentId: Int64? = nil, model: String,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
        costUSD: Double, recordedAt: Date
    ) {
        self.id = id
        self.projectId = projectId
        self.runId = runId
        self.agentId = agentId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.recordedAt = recordedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let costUSD = Column(CodingKeys.costUSD)
        public static let recordedAt = Column(CodingKeys.recordedAt)
    }
}
