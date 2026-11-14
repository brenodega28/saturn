import Foundation
import GRDB

public enum ChatActionError: Error, LocalizedError, Equatable {
    case emptyTitle
    case notFound

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "A chat needs a name."
        case .notFound: "The chat is gone."
        }
    }
}

public enum ChatActivity {
    public static func isUnread(viewedAt: Date?, createdAt: Date, lastActivity: Date?) -> Bool {
        guard let lastActivity else { return false }
        return lastActivity > (viewedAt ?? createdAt)
    }
}

extension AppDatabase {
    @discardableResult
    public func renameChat(id: Int64, to title: String, now: Date = .now) throws -> Chat {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatActionError.emptyTitle }
        return try writer.write { db in
            try db.execute(sql: "UPDATE task SET title = ?, updatedAt = ? WHERE id = ?", arguments: [trimmed, now, id])
            guard let chat = try Chat.fetchOne(db, id: id) else { throw ChatActionError.notFound }
            return chat
        }
    }

    public func markViewed(chatId: Int64, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE task SET viewedAt = ? WHERE id = ?", arguments: [date, chatId])
        }
    }

    public func setLead(model: String?, effort: LeadEffort?, chatId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE task SET leadModel = ?, leadEffort = ? WHERE id = ?", arguments: [model, effort?.rawValue, chatId])
        }
    }

    public func setWorkflow(_ workflow: String?, chatId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE task SET workflow = ? WHERE id = ?", arguments: [workflow, chatId])
        }
    }

    public func deleteChat(id: Int64) throws {
        try writer.write { db in
            _ = try Chat.deleteOne(db, id: id)
        }
    }

    public func openProposalChatIDs(projectId: Int64) throws -> Set<Int64> {
        try writer.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT taskId FROM leadMessage
                WHERE projectId = ? AND kind = 'proposal' AND status = 'open'
                """, arguments: [projectId]))
        }
    }

    public func lastActivity(projectId: Int64) throws -> [Int64: Date] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT taskId, MAX(at) AS at FROM (
                    SELECT leadMessage.taskId AS taskId, leadMessage.createdAt AS at FROM leadMessage
                    WHERE leadMessage.projectId = ? AND leadMessage.kind <> 'user'
                    UNION ALL
                    SELECT chatRequest.taskId, chatRequest.createdAt FROM chatRequest WHERE chatRequest.projectId = ?
                    UNION ALL
                    SELECT run.taskId, COALESCE(run.endedAt, run.startedAt) FROM run WHERE run.projectId = ?
                ) GROUP BY taskId
                """, arguments: [projectId, projectId, projectId])
            var latest: [Int64: Date] = [:]
            for row in rows {
                let chatID: Int64 = row["taskId"]
                guard let at: Date = row["at"] else { continue }
                latest[chatID] = max(latest[chatID] ?? at, at)
            }
            return latest
        }
    }
}

extension LeadChat {
    public func setLead(model: String?, effort: LeadEffort?, for chat: Chat) throws {
        guard let id = chat.id else { throw ChatActionError.notFound }
        try database.setLead(model: model, effort: effort, chatId: id)
        if let model, let session = leadSession(for: chat) { session.setModel(model) }
    }

    @discardableResult
    public func reopen(_ chat: Chat, now: Date = .now) throws -> Chat {
        guard let id = chat.id, let reopened = try database.setClosed(taskId: id, reason: nil, at: now) else { throw ChatActionError.notFound }
        return reopened
    }

    public func delete(_ chat: Chat, in project: Project, git: GitClient) async throws {
        guard let id = chat.id else { throw ChatActionError.notFound }
        guard !(try database.runs(taskId: id).contains { (engine.runs[$0.id ?? -1] ?? $0).isActive }) else { throw LeadChatError.runInProgress }
        let agents = try database.requestAgents(taskId: id) + (try database.leadAgent(taskId: id).map { [$0] } ?? [])
        for agent in agents {
            guard let session = runtime.session(for: agent) else { continue }
            try await runtime.delete(session, in: project, git: git, deleteBranch: true)
        }
        try database.deleteChat(id: id)
    }
}
