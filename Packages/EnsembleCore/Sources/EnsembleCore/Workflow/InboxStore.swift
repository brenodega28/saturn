import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func createInboxItem(_ item: InboxItem) throws -> InboxItem {
        try writer.write { db in
            var item = item
            try item.insert(db)
            return item
        }
    }

    public func inboxItem(id: Int64) throws -> InboxItem? {
        try writer.read { db in try InboxItem.fetchOne(db, id: id) }
    }

    @discardableResult
    public func resolveInboxItem(id: Int64, response: String? = nil, status: InboxStatus = .resolved, now: Date = .now) throws -> InboxItem? {
        try writer.write { db in
            guard var item = try InboxItem.fetchOne(db, id: id) else { return nil }
            item.status = status
            item.response = response
            item.resolvedAt = now
            try item.update(db)
            return item
        }
    }

    public func openInboxItems(projectId: Int64) throws -> [InboxItem] {
        try writer.read { db in
            try InboxItem
                .filter(InboxItem.Columns.projectId == projectId)
                .filter(InboxItem.Columns.status == InboxStatus.open.rawValue)
                .order(InboxItem.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }

    public func inboxItems(runId: Int64) throws -> [InboxItem] {
        try writer.read { db in
            try InboxItem
                .filter(InboxItem.Columns.runId == runId)
                .order(InboxItem.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }
}
