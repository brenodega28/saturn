import Foundation
import GRDB

extension AppDatabase {
    public func usageCosts(projectId: Int64, since start: Date) throws -> [(date: Date, cost: Double)] {
        try writer.read { db in
            try UsageEntry
                .filter(Column("projectId") == projectId && UsageEntry.Columns.recordedAt >= start)
                .fetchAll(db)
                .map { (date: $0.recordedAt, cost: $0.costUSD) }
        }
    }
}
