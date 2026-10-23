import Foundation
import GRDB

public enum WriteBackEvent: String, Codable, Sendable, CaseIterable {
    case started
    case ended
}

public struct PendingWriteBack: Sendable, Hashable {
    public var run: Run
    public var issue: Int
    public var repository: String
    public var startedSent: Bool
    public var endedSent: Bool

    public var conclusion: GitHubWriteBack.Conclusion? {
        switch run.status {
        case .succeeded: .succeeded
        case .failed: .failed
        default: nil
        }
    }

    public var needsStart: Bool { !startedSent && run.status != .cancelled }

    public var needsEnd: Bool { !endedSent && conclusion != nil }
}

extension AppDatabase {
    static func registerGitHubMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-github") { db in
            try db.create(table: "githubWriteBack") { t in
                t.belongsTo("run", onDelete: .cascade).notNull()
                t.column("event", .text).notNull()
                t.column("sentAt", .datetime).notNull()
                t.primaryKey(["runId", "event"])
            }
            try db.create(index: "task_on_repository_externalNumber", on: "task", columns: ["repository", "externalNumber"])
        }
    }

    public func hasImportedIssue(_ number: Int, repository: String) throws -> Bool {
        try writer.read { db in
            try ProjectTask
                .filter(Column("repository") == repository)
                .filter(ProjectTask.Columns.externalNumber == number)
                .filter(ProjectTask.Columns.source == TaskSource.github.rawValue)
                .fetchCount(db) > 0
        }
    }

    public func importedIssueNumbers(repository: String) throws -> Set<Int> {
        try writer.read { db in
            let numbers = try Int.fetchAll(
                db,
                sql: "SELECT externalNumber FROM task WHERE source = ? AND repository = ? AND externalNumber IS NOT NULL",
                arguments: [TaskSource.github.rawValue, repository]
            )
            return Set(numbers)
        }
    }

    public func pendingGitHubWriteBacks() throws -> [PendingWriteBack] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT run.*,
                       task.externalNumber AS issueNumber,
                       task.repository AS issueRepository,
                       EXISTS(SELECT 1 FROM githubWriteBack w WHERE w.runId = run.id AND w.event = ?) AS startedSent,
                       EXISTS(SELECT 1 FROM githubWriteBack w WHERE w.runId = run.id AND w.event = ?) AS endedSent
                FROM run
                JOIN task ON task.id = run.taskId
                WHERE task.source = ? AND task.externalNumber IS NOT NULL AND task.repository IS NOT NULL
                ORDER BY run.id
                """, arguments: [WriteBackEvent.started.rawValue, WriteBackEvent.ended.rawValue, TaskSource.github.rawValue])
            return try rows.compactMap { row -> PendingWriteBack? in
                let pending = PendingWriteBack(
                    run: try Run(row: row),
                    issue: row["issueNumber"],
                    repository: row["issueRepository"],
                    startedSent: row["startedSent"],
                    endedSent: row["endedSent"]
                )
                return pending.needsStart || pending.needsEnd ? pending : nil
            }
        }
    }

    public func recordWriteBack(_ event: WriteBackEvent, runId: Int64, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO githubWriteBack (runId, event, sentAt) VALUES (?, ?, ?)",
                arguments: [runId, event.rawValue, date]
            )
        }
    }

    public func writeBackEvents(runId: Int64) throws -> Set<WriteBackEvent> {
        try writer.read { db in
            let names = try String.fetchAll(db, sql: "SELECT event FROM githubWriteBack WHERE runId = ?", arguments: [runId])
            return Set(names.compactMap(WriteBackEvent.init(rawValue:)))
        }
    }
}
