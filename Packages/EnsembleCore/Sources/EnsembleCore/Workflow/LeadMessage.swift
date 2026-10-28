import Foundation
import GRDB

public enum LeadMessageKind: String, Codable, Sendable, Hashable {
    case user
    case lead
    case proposal
    case note
}

public enum ProposalStatus: String, Codable, Sendable, Hashable {
    case open
    case started
    case dismissed
}

public struct LeadMessage: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "leadMessage"

    public var id: Int64?
    public var projectId: Int64
    public var taskId: Int64
    public var kind: LeadMessageKind
    public var text: String
    public var workflow: String?
    public var title: String?
    public var status: ProposalStatus?
    public var runId: Int64?
    public var createdAt: Date
    public var attachments: [StoredChatAttachment]?

    public init(
        id: Int64? = nil, projectId: Int64, taskId: Int64, kind: LeadMessageKind, text: String,
        workflow: String? = nil, title: String? = nil, status: ProposalStatus? = nil, runId: Int64? = nil, createdAt: Date,
        attachments: [StoredChatAttachment]? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.taskId = taskId
        self.kind = kind
        self.text = text
        self.workflow = workflow
        self.title = title
        self.status = status
        self.runId = runId
        self.createdAt = createdAt
        self.attachments = attachments
    }

    public var storedAttachments: [StoredChatAttachment] { attachments ?? [] }

    public var chatAttachments: [ChatAttachment] { storedAttachments.attachments }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let taskId = Column(CodingKeys.taskId)
        public static let projectId = Column(CodingKeys.projectId)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}

public struct RunProposal: Sendable, Hashable, Codable {
    public var workflow: String
    public var title: String
    public var brief: String

    public init(workflow: String, title: String, brief: String) {
        self.workflow = workflow
        self.title = title
        self.brief = brief
    }
}

extension AppDatabase {
    @discardableResult
    public func insert(_ message: LeadMessage) throws -> LeadMessage {
        try writer.write { db in
            var message = message
            try message.insert(db)
            try db.execute(sql: "UPDATE task SET updatedAt = ? WHERE id = ?", arguments: [message.createdAt, message.taskId])
            return message
        }
    }

    public func save(_ message: LeadMessage) throws {
        try writer.write { db in try message.update(db) }
    }

    public func leadMessages(taskId: Int64) throws -> [LeadMessage] {
        try writer.read { db in
            try LeadMessage
                .filter(LeadMessage.Columns.taskId == taskId)
                .order(LeadMessage.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }

    public func leadMessage(id: Int64) throws -> LeadMessage? {
        try writer.read { db in try LeadMessage.fetchOne(db, key: id) }
    }

    public func leadAgent(taskId: Int64) throws -> Agent? {
        try writer.read { db in
            try Agent.filter(Column("taskId") == taskId).order(Column("id")).fetchOne(db)
        }
    }

    public func requestAgents(taskId: Int64) throws -> [Agent] {
        try writer.read { db in
            try Agent.fetchAll(db, sql: """
                SELECT agent.* FROM agent
                WHERE agent.taskId = ?
                   OR agent.runId IN (SELECT id FROM run WHERE run.taskId = ?)
                ORDER BY agent.id
                """, arguments: [taskId, taskId])
        }
    }

    public func spawnedAgents(taskId: Int64) throws -> [Agent] {
        try writer.read { db in
            try Agent.fetchAll(db, sql: """
                SELECT agent.* FROM agent
                WHERE agent.spawnedById IN (
                    SELECT spawner.id FROM agent AS spawner
                    WHERE spawner.taskId = ?
                       OR spawner.runId IN (SELECT id FROM run WHERE run.taskId = ?)
                )
                ORDER BY agent.id
                """, arguments: [taskId, taskId])
        }
    }

    public func closedTasks(projectId: Int64) throws -> [ProjectTask] {
        try writer.read { db in
            try ProjectTask.fetchAll(db, sql: """
                SELECT task.* FROM task
                WHERE task.projectId = ? AND task.closedAt IS NOT NULL
                ORDER BY task.id
                """, arguments: [projectId])
        }
    }

    @discardableResult
    public func setClosed(taskId: Int64, reason: RequestCloseReason?, at date: Date) throws -> ProjectTask? {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE task SET closedAt = ?, closeReason = ?, updatedAt = ? WHERE id = ?",
                arguments: [reason == nil ? nil : date, reason?.rawValue, date, taskId]
            )
            return try ProjectTask.fetchOne(db, id: taskId)
        }
    }

    public func runs(taskId: Int64) throws -> [Run] {
        try writer.read { db in
            try Run.filter(Column("taskId") == taskId).order(Column("startedAt"), Column("id")).fetchAll(db)
        }
    }

    public func requestQuestions(taskId: Int64) throws -> [InboxItem] {
        try writer.read { db in
            try InboxItem.fetchAll(db, sql: """
                SELECT inboxItem.* FROM inboxItem
                WHERE inboxItem.kind = 'question'
                  AND (inboxItem.runId IN (SELECT id FROM run WHERE run.taskId = ?)
                       OR inboxItem.agentId IN (SELECT id FROM agent WHERE agent.taskId = ?))
                ORDER BY inboxItem.createdAt, inboxItem.id
                """, arguments: [taskId, taskId])
        }
    }

    public func leadRequests(projectId: Int64) throws -> [ProjectTask] {
        try writer.read { db in
            try ProjectTask.fetchAll(db, sql: """
                SELECT task.* FROM task
                WHERE task.projectId = ?
                  AND (EXISTS (SELECT 1 FROM run WHERE run.taskId = task.id)
                       OR EXISTS (SELECT 1 FROM leadMessage WHERE leadMessage.taskId = task.id))
                ORDER BY task.updatedAt DESC, task.id DESC
                """, arguments: [projectId])
        }
    }
}
