import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static var defaultLocation: URL { AppPaths.standard.database }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("isOpen", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime).notNull().indexed()
            }

            try db.create(table: "task") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("source", .text).notNull()
                t.column("sourceURL", .text)
                t.column("workflow", .text)
                t.column("status", .text).notNull().indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "run") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.belongsTo("task", onDelete: .cascade).notNull()
                t.column("workflow", .text).notNull()
                t.column("workflowVersion", .text)
                t.column("currentStep", .text)
                t.column("status", .text).notNull().indexed()
                t.column("outcome", .text)
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }

            try db.create(table: "agent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.belongsTo("run", onDelete: .setNull)
                t.column("role", .text).notNull()
                t.column("name", .text).notNull()
                t.column("step", .text)
                t.column("worktreePath", .text)
                t.column("branch", .text)
                t.column("status", .text).notNull()
                t.column("sessionId", .text)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["projectId", "name"])
            }

            try db.create(table: "usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.belongsTo("run", onDelete: .setNull)
                t.belongsTo("agent", onDelete: .setNull)
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheWriteTokens", .integer).notNull().defaults(to: 0)
                t.column("costUSD", .double).notNull()
                t.column("recordedAt", .datetime).notNull().indexed()
            }
        }

        migrator.registerMigration("v2-agent-sessions") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "model", .text).notNull().defaults(to: "sonnet")
                t.add(column: "task", .text).notNull().defaults(to: "")
                t.add(column: "baseBranch", .text)
                t.add(column: "cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.add(column: "cacheWriteTokens", .integer).notNull().defaults(to: 0)
                t.add(column: "processID", .integer)
                t.add(column: "lastError", .text)
            }
        }

        migrator.registerMigration("v3-workflows") { db in
            try db.alter(table: "project") { t in
                t.add(column: "settings", .text).notNull().defaults(to: "{}")
            }
            try db.alter(table: "task") { t in
                t.add(column: "externalNumber", .integer)
                t.add(column: "repository", .text)
                t.add(column: "labels", .text).notNull().defaults(to: "[]")
            }
            try db.alter(table: "run") { t in
                t.add(column: "title", .text).notNull().defaults(to: "")
                t.add(column: "workflowSnapshot", .text).notNull().defaults(to: "")
                t.add(column: "budgetUSD", .double)
                t.add(column: "endAction", .text)
                t.add(column: "pullRequestURL", .text)
                t.add(column: "lastError", .text)
            }
            try db.create(table: "runStep") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("run", onDelete: .cascade).notNull()
                t.column("stepId", .text).notNull()
                t.column("iteration", .integer).notNull().defaults(to: 1)
                t.column("status", .text).notNull()
                t.column("outcome", .text)
                t.column("output", .text)
                t.column("input", .text)
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.alter(table: "agent") { t in
                t.add(column: "runStepId", .integer).references("runStep", onDelete: .setNull)
                t.add(column: "readOnly", .boolean).notNull().defaults(to: false)
                t.add(column: "planTaskId", .text)
            }
            try db.create(table: "pin") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("run", onDelete: .cascade).notNull()
                t.belongsTo("agent", onDelete: .setNull)
                t.column("file", .text).notNull()
                t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("explanation", .text).notNull()
                t.column("status", .text).notNull()
                t.column("response", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "inboxItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.belongsTo("run", onDelete: .cascade)
                t.belongsTo("agent", onDelete: .setNull)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().indexed()
                t.column("response", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("resolvedAt", .datetime)
            }
        }

        migrator.registerMigration("v4-workflow-engine") { db in
            try db.alter(table: "run") { t in
                t.add(column: "engineState", .text).notNull().defaults(to: "{}")
            }
        }

        registerGitHubMigration(in: &migrator)
        migrator.registerMigration("v5-review", migrate: createReviewTables)

        return migrator
    }
}
