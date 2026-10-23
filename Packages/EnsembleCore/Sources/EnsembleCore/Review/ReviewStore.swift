import Foundation
import GRDB

struct ViewedFile: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewViewedFile"

    var runId: Int64
    var path: String
    var fingerprint: String
    var viewedAt: Date
}

extension AppDatabase {
    static func createReviewTables(_ db: Database) throws {
        try db.create(table: ViewedFile.databaseTableName) { t in
            t.belongsTo("run", onDelete: .cascade).notNull()
            t.column("path", .text).notNull()
            t.column("fingerprint", .text).notNull()
            t.column("viewedAt", .datetime).notNull()
            t.primaryKey(["runId", "path"])
        }
    }

    public func viewedFingerprints(runId: Int64) throws -> [String: String] {
        try writer.read { db in
            let rows = try ViewedFile.filter(Column("runId") == runId).fetchAll(db)
            return Dictionary(rows.map { ($0.path, $0.fingerprint) }, uniquingKeysWith: { _, latest in latest })
        }
    }

    public func viewedPaths(runId: Int64, current: [ChangedPath]) throws -> Set<String> {
        let stored = try viewedFingerprints(runId: runId)
        return Set(current.filter { stored[$0.path] == $0.fingerprint }.map(\.path))
    }

    public func setViewed(_ viewed: Bool, runId: Int64, path: String, fingerprint: String, now: Date = .now) throws {
        try writer.write { db in
            if viewed {
                try ViewedFile(runId: runId, path: path, fingerprint: fingerprint, viewedAt: now).save(db)
            } else {
                _ = try ViewedFile.deleteOne(db, key: ["runId": runId, "path": path])
            }
        }
    }

    public func agents(inRun runId: Int64) throws -> [Agent] {
        try writer.read { db in
            try Agent.filter(Agent.Columns.runId == runId).order(Agent.Columns.createdAt, Column("id")).fetchAll(db)
        }
    }
}
