import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func createChatRequest(_ item: ChatRequest) throws -> ChatRequest {
        try writer.write { db in try ChatRequest.insertAttached(item, db) }
    }

    public func chatRequests(taskId: Int64) throws -> [ChatRequest] {
        try writer.read { db in
            try ChatRequest
                .filter(ChatRequest.Columns.taskId == taskId)
                .order(ChatRequest.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }

    public func chatRequest(id: Int64) throws -> ChatRequest? {
        try writer.read { db in try ChatRequest.fetchOne(db, id: id) }
    }

    @discardableResult
    public func resolveChatRequest(id: Int64, response: String? = nil, status: ChatRequestState = .answered, now: Date = .now) throws -> ChatRequest? {
        try writer.write { db in
            guard var item = try ChatRequest.fetchOne(db, id: id) else { return nil }
            item.status = status
            item.response = response
            item.resolvedAt = now
            try item.update(db)
            return item
        }
    }

    public func openChatRequests(projectId: Int64) throws -> [ChatRequest] {
        try writer.read { db in
            try ChatRequest
                .filter(ChatRequest.Columns.projectId == projectId)
                .filter(ChatRequest.Columns.status == ChatRequestState.open.rawValue)
                .order(ChatRequest.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }

    public func chatRequests(runId: Int64) throws -> [ChatRequest] {
        try writer.read { db in
            try ChatRequest
                .filter(ChatRequest.Columns.runId == runId)
                .order(ChatRequest.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }
}

extension ChatRequest {
    static func insertAttached(_ request: ChatRequest, _ db: Database) throws -> ChatRequest {
        var request = request
        request.taskId = try chatID(for: request, db)
        try request.insert(db)
        return request
    }

    static func chatID(for request: ChatRequest, _ db: Database) throws -> Int64 {
        if let taskId = request.taskId { return taskId }
        if let runId = request.runId, let taskId = try Int64.fetchOne(db, sql: "SELECT taskId FROM run WHERE id = ?", arguments: [runId]) {
            return taskId
        }
        if let agentId = request.agentId, let taskId = try Int64.fetchOne(db, sql: "SELECT taskId FROM agent WHERE id = ?", arguments: [agentId]) {
            return taskId
        }
        if let taskId = try latestOpenChatID(projectId: request.projectId, db) {
            return taskId
        }
        var chat = ProjectTask(
            projectId: request.projectId, title: request.title, body: request.body, source: .chat,
            status: request.status == .open ? .waitingOnYou : .done, createdAt: request.createdAt, updatedAt: request.createdAt
        )
        try chat.insert(db)
        guard let id = chat.id else { throw DatabaseError(message: "The new chat for “\(request.title)” has no id.") }
        return id
    }

    static func latestOpenChatID(projectId: Int64, _ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT id FROM task WHERE projectId = ? AND closedAt IS NULL
            ORDER BY updatedAt DESC, id DESC LIMIT 1
            """, arguments: [projectId])
    }
}
