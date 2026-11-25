import Foundation
import GRDB

public enum LeadMessageKind: String, Codable, Sendable, Hashable {
    case user
    case lead
    case proposal
    case note
    case permission
    case specFeedback
    case specDraft
    case setupProposal
}

public enum ProposalStatus: String, Codable, Sendable, Hashable {
    case open
    case starting
    case started
    case dismissed
    case applied
}

public enum PermissionCardStatus: String, Codable, Sendable, Hashable {
    case pending
    case allowed
    case allowedOnce
    case allowedForRun
    case denied

    init(_ decision: PermissionDecision) {
        switch decision {
        case .allow: self = .allowed
        case .deny: self = .denied
        }
    }
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
    public var permissionRequestId: Int64?
    public var permissionStatus: PermissionCardStatus?
    public var capability: PermissionCapability?

    public init(
        id: Int64? = nil, projectId: Int64, taskId: Int64, kind: LeadMessageKind, text: String,
        workflow: String? = nil, title: String? = nil, status: ProposalStatus? = nil, runId: Int64? = nil, createdAt: Date,
        attachments: [StoredChatAttachment]? = nil, permissionRequestId: Int64? = nil, permissionStatus: PermissionCardStatus? = nil,
        capability: PermissionCapability? = nil
    ) {
        self.permissionRequestId = permissionRequestId
        self.permissionStatus = permissionStatus
        self.capability = capability
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

    public var setupProposal: SetupProposal? {
        guard kind == .setupProposal else { return nil }
        return SetupProposal.decode(json: text)
    }

    public var specDraft: SpecDraftInfo? {
        guard kind == .specDraft else { return nil }
        return try? JSONDecoder().decode(SpecDraftInfo.self, from: Data(text.utf8))
    }

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

public struct SpecDraftInfo: Codable, Sendable, Hashable {
    public var version: Int
    public var criteria: Int
    public var url: String?
    public var reason: String?

    public init(version: Int, criteria: Int, review: SpecReviewStatus) {
        self.version = version
        self.criteria = criteria
        self.url = review.url
        self.reason = review.reason
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public func summary(title: String) -> String {
        let count = "\(criteria) acceptance criteri\(criteria == 1 ? "on" : "a")"
        let page = url.map { "review page \($0)" } ?? "review page not opened: \(reason ?? "unknown reason")"
        return "Spec v\(version) “\(title)” · \(count) · \(page)"
    }
}

extension AppDatabase {
    @discardableResult
    public func insertSpecDraft(projectId: Int64, taskId: Int64, title: String, info: SpecDraftInfo, at date: Date = .now) throws -> LeadMessage {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE leadMessage SET status = ? WHERE taskId = ? AND kind = ? AND status = ?",
                arguments: [ProposalStatus.dismissed.rawValue, taskId, LeadMessageKind.specDraft.rawValue, ProposalStatus.open.rawValue]
            )
            var message = LeadMessage(projectId: projectId, taskId: taskId, kind: .specDraft, text: info.json, title: title, status: .open, createdAt: date)
            try message.insert(db)
            try db.execute(sql: "UPDATE task SET updatedAt = ? WHERE id = ?", arguments: [date, taskId])
            return message
        }
    }

    @discardableResult
    public func insertSetupProposal(_ proposal: SetupProposal, projectId: Int64, taskId: Int64, at date: Date = .now) throws -> LeadMessage {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE leadMessage SET status = ? WHERE taskId = ? AND kind = ? AND status = ?",
                arguments: [ProposalStatus.dismissed.rawValue, taskId, LeadMessageKind.setupProposal.rawValue, ProposalStatus.open.rawValue]
            )
            var message = LeadMessage(projectId: projectId, taskId: taskId, kind: .setupProposal, text: proposal.json, title: "Project setup", status: .open, createdAt: date)
            try message.insert(db)
            try db.execute(sql: "UPDATE task SET updatedAt = ? WHERE id = ?", arguments: [date, taskId])
            return message
        }
    }

    public func openSpecDraft(taskId: Int64) throws -> LeadMessage? {
        try writer.read { db in
            try LeadMessage
                .filter(LeadMessage.Columns.taskId == taskId && Column("kind") == LeadMessageKind.specDraft.rawValue && Column("status") == ProposalStatus.open.rawValue)
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }

    public func markSpecDraftStarted(taskId: Int64, runId: Int64?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE leadMessage SET status = ?, runId = ? WHERE taskId = ? AND kind = ? AND status = ?",
                arguments: [ProposalStatus.started.rawValue, runId, taskId, LeadMessageKind.specDraft.rawValue, ProposalStatus.open.rawValue]
            )
        }
    }

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

    public func permissionCard(requestId: Int64) throws -> LeadMessage? {
        try writer.read { db in
            try LeadMessage.filter(Column("kind") == LeadMessageKind.permission.rawValue && Column("permissionRequestId") == requestId).fetchOne(db)
        }
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

    public func previousRunAgents(taskId: Int64) throws -> [Agent] {
        let leadId = try leadAgent(taskId: taskId)?.id
        var seen = Set<Int64>()
        return try (requestAgents(taskId: taskId) + spawnedAgents(taskId: taskId)).filter { agent in
            guard let id = agent.id, id != leadId, agent.archivedAt == nil else { return false }
            return seen.insert(id).inserted
        }
    }

    public func previousRunSummary(of agents: [Agent]) -> String {
        "\(agents.count) agent\(agents.count == 1 ? "" : "s") from earlier runs"
    }

    public func closedTasks(projectId: Int64) throws -> [Chat] {
        try writer.read { db in
            try Chat.fetchAll(db, sql: """
                SELECT task.* FROM task
                WHERE task.projectId = ? AND task.closedAt IS NOT NULL
                ORDER BY task.id
                """, arguments: [projectId])
        }
    }

    @discardableResult
    public func setClosed(taskId: Int64, reason: RequestCloseReason?, at date: Date) throws -> Chat? {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE task SET closedAt = ?, closeReason = ?, finishedAt = NULL, updatedAt = ? WHERE id = ?",
                arguments: [reason == nil ? nil : date, reason?.rawValue, date, taskId]
            )
            return try Chat.fetchOne(db, id: taskId)
        }
    }

    @discardableResult
    public func setFinished(taskId: Int64, at date: Date) throws -> Chat? {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE task SET finishedAt = ?, closedAt = NULL, closeReason = NULL, updatedAt = ? WHERE id = ?",
                arguments: [date, date, taskId]
            )
            return try Chat.fetchOne(db, id: taskId)
        }
    }

    public func runs(taskId: Int64) throws -> [Run] {
        try writer.read { db in
            try Run.filter(Column("taskId") == taskId).order(Column("startedAt"), Column("id")).fetchAll(db)
        }
    }

    public func requestQuestions(taskId: Int64) throws -> [ChatRequest] {
        try writer.read { db in
            try ChatRequest
                .filter(ChatRequest.Columns.taskId == taskId)
                .filter(Column("kind") == ChatRequestKind.question.rawValue)
                .order(ChatRequest.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }

    public func leadRequests(projectId: Int64) throws -> [Chat] {
        try writer.read { db in
            try Chat.fetchAll(db, sql: """
                SELECT task.* FROM task
                WHERE task.projectId = ?
                  AND (EXISTS (SELECT 1 FROM run WHERE run.taskId = task.id)
                       OR EXISTS (SELECT 1 FROM leadMessage WHERE leadMessage.taskId = task.id)
                       OR EXISTS (SELECT 1 FROM chatRequest WHERE chatRequest.taskId = task.id))
                ORDER BY task.updatedAt DESC, task.id DESC
                """, arguments: [projectId])
        }
    }
}
