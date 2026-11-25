import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public let isReplica: Bool

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        self.isReplica = false
        try Self.migrator.migrate(writer)
    }

    init(replicaWriter writer: any DatabaseWriter) {
        self.writer = writer
        self.isReplica = true
    }

    public static var latestMigration: String {
        migrator.migrations.last ?? ""
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

        migrator.registerMigration("v5-github") { db in
            try db.create(table: "githubWriteBack") { t in
                t.belongsTo("run", onDelete: .cascade).notNull()
                t.column("event", .text).notNull()
                t.column("sentAt", .datetime).notNull()
                t.primaryKey(["runId", "event"])
            }
            try db.create(index: "task_on_repository_externalNumber", on: "task", columns: ["repository", "externalNumber"])
        }
        migrator.registerMigration("v5-review", migrate: createReviewTables)
        migrator.registerMigration("v6-workspaces") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "port", .integer)
                t.add(column: "archivedAt", .datetime)
            }
        }
        migrator.registerMigration("v7-inbox-questions") { db in
            try db.alter(table: "inboxItem") { t in
                t.add(column: "questions", .text)
            }
        }
        migrator.registerMigration("v8-lead-chat") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "taskId", .integer).references("task", onDelete: .setNull)
            }
            try db.alter(table: "run") { t in
                t.add(column: "brief", .text)
            }
            try db.create(table: "leadMessage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("projectId", .integer).notNull().indexed().references("project", onDelete: .cascade)
                t.column("taskId", .integer).notNull().indexed().references("task", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("workflow", .text)
                t.column("title", .text)
                t.column("status", .text)
                t.column("runId", .integer).references("run", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v9-direct-messages") { db in
            try db.create(table: "directMessage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("projectId", .integer).notNull().indexed().references("project", onDelete: .cascade)
                t.column("agentId", .integer).notNull().indexed().references("agent", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("awaitingReply", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v10-request-closing") { db in
            try db.alter(table: "task") { t in
                t.add(column: "closedAt", .datetime)
                t.add(column: "closeReason", .text)
            }
        }
        migrator.registerMigration("v11-chat-attachments") { db in
            try db.alter(table: "leadMessage") { t in
                t.add(column: "attachments", .text)
            }
            try db.alter(table: "directMessage") { t in
                t.add(column: "attachments", .text)
            }
        }
        migrator.registerMigration("v12-merge-delivery") { db in
            try db.alter(table: "run") { t in
                t.add(column: "deliveryBranch", .text)
                t.add(column: "baseBranch", .text)
                t.add(column: "mergedAt", .datetime)
            }
        }
        migrator.registerMigration("v13-pin-comments") { db in
            try db.alter(table: "pin") { t in
                t.add(column: "side", .text).notNull().defaults(to: PinSide.new.rawValue)
                t.add(column: "byUser", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v14-review-gates") { db in
            try db.alter(table: "pin") { t in
                t.add(column: "confidence", .double)
                t.add(column: "category", .text)
            }
            try db.create(table: "evidence") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("run", onDelete: .cascade).notNull()
                t.column("agentId", .integer)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("file", .text).notNull()
                t.column("note", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v15-close-the-loop") { db in
            try db.alter(table: "run") { t in
                t.add(column: "linesChanged", .integer)
                t.add(column: "filesChanged", .integer)
            }
            try db.create(table: "correction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("runId", .integer)
                t.column("pinId", .integer)
                t.column("file", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("encodedAt", .datetime)
                t.column("encoding", .text)
            }
        }
        migrator.registerMigration("v16-permission-requests") { db in
            try db.create(table: "permissionRequest") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("agentId", .integer).notNull()
                t.column("capability", .text).notNull()
                t.column("request", .text).notNull()
                t.column("status", .text).notNull()
                t.column("inboxItemId", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("answeredAt", .datetime)
            }
        }
        migrator.registerMigration("v17-spawned-agents") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "spawnedById", .integer)
            }
        }
        migrator.registerMigration("v18-session-cost-baseline") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "sessionCostUSD", .double).notNull().defaults(to: 0)
                t.add(column: "sessionOutputTokens", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v19-agent-kinds") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "skills", .text).notNull().defaults(to: "[]")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, role, readOnly, taskId FROM agent")
            for row in rows {
                let role: String = row["role"]
                guard AgentKind(rawValue: role) == nil else { continue }
                let readOnly: Bool = row["readOnly"]
                let taskId: Int64? = row["taskId"]
                let guessed = AgentKind.guessing(roleID: role)
                let kind: AgentKind = taskId != nil || guessed == .lead ? .lead : readOnly ? .checker : .builder
                try db.execute(sql: "UPDATE agent SET role = ? WHERE id = ?", arguments: [kind.rawValue, row["id"] as Int64])
            }
        }
        migrator.registerMigration("v20-permission-scopes") { db in
            try db.alter(table: "permissionRequest") { t in
                t.add(column: "scope", .text).notNull().defaults(to: PermissionScope.once.rawValue)
                t.add(column: "runId", .integer)
                t.add(column: "consumedAt", .datetime)
            }
            try db.alter(table: "leadMessage") { t in
                t.add(column: "permissionRequestId", .integer)
                t.add(column: "permissionStatus", .text)
                t.add(column: "capability", .text)
            }
        }
        migrator.registerMigration("v21-remote-projects") { db in
            try db.create(table: "project_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("host", .text)
                t.column("isOpen", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime).notNull().indexed()
                t.column("settings", .text).notNull().defaults(to: "{}")
            }
            try db.execute(sql: """
                INSERT INTO project_new (id, name, path, isOpen, createdAt, lastOpenedAt, settings)
                SELECT id, name, path, isOpen, createdAt, lastOpenedAt, settings FROM project
                """)
            try db.drop(table: "project")
            try db.rename(table: "project_new", to: "project")
            try db.execute(sql: "CREATE UNIQUE INDEX project_location ON project (ifnull(host, ''), path)")
        }
        migrator.registerMigration("v22-permission-chat-rules") { db in
            try db.alter(table: "permissionRequest") { t in
                t.add(column: "taskId", .integer)
                t.add(column: "rules", .text).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v23-chat-first") { db in
            try db.execute(sql: "UPDATE task SET source = 'chat' WHERE source <> 'chat'")
            try db.execute(sql: "DROP INDEX IF EXISTS task_on_repository_externalNumber")
            try db.drop(table: "githubWriteBack")
            try db.drop(table: "directMessage")
            try db.alter(table: "run") { t in
                t.add(column: "pushedAt", .datetime)
            }
        }
        migrator.registerMigration("v24-chat-requests", migrate: moveInboxIntoChats)
        migrator.registerMigration("v25-chat-state") { db in
            try db.alter(table: "task") { t in
                t.add(column: "viewedAt", .datetime)
                t.add(column: "leadModel", .text)
                t.add(column: "leadEffort", .text)
            }
        }

        migrator.registerMigration("v26-change-log") { db in
            try db.create(table: ChangeLog.tableName) { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("tableName", .text).notNull()
                t.column("op", .text).notNull()
                t.column("rowID", .integer).notNull()
                t.column("row", .text)
            }
        }
        migrator.registerMigration("v27-chat-finished") { db in
            try db.alter(table: "task") { t in
                t.add(column: "finishedAt", .datetime)
            }
        }
        migrator.registerMigration("v28-no-budget-holds", migrate: releaseBudgetHolds)

        return migrator
    }

    static func releaseBudgetHolds(_ db: Database) throws {
        let message = "Budget limits were removed from Ensemble. Retry the step to continue."
        try db.execute(sql: """
            UPDATE chatRequest SET kind = ?, body = ?
            WHERE status = 'open' AND id IN (
                SELECT json_extract(engineState, '$.hold.requestId') FROM run
                WHERE json_extract(engineState, '$.hold.reason') IN ('step_budget', 'run_budget')
            )
            """, arguments: [ChatRequestKind.failure.rawValue, message])
        try db.execute(sql: """
            UPDATE run SET engineState = json_set(engineState, '$.hold.reason', 'step_failed', '$.hold.message', ?)
            WHERE json_extract(engineState, '$.hold.reason') IN ('step_budget', 'run_budget')
            """, arguments: [message])
    }

    static func moveInboxIntoChats(_ db: Database) throws {
        try db.create(table: "chatRequest") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("project", onDelete: .cascade).notNull()
            t.belongsTo("task", onDelete: .cascade).notNull()
            t.belongsTo("run", onDelete: .cascade)
            t.belongsTo("agent", onDelete: .setNull)
            t.column("kind", .text).notNull()
            t.column("title", .text).notNull()
            t.column("body", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull().indexed()
            t.column("response", .text)
            t.column("questions", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("resolvedAt", .datetime)
        }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM inboxItem ORDER BY id")
        for row in rows {
            let status: String = row["status"] == "resolved" ? "answered" : row["status"]
            let projectId: Int64 = row["projectId"]
            let runId: Int64? = row["runId"]
            let agentId: Int64? = row["agentId"]
            var chatId = try runId.flatMap { try Int64.fetchOne(db, sql: "SELECT taskId FROM run WHERE id = ?", arguments: [$0]) }
            if chatId == nil, let agentId {
                chatId = try Int64.fetchOne(db, sql: "SELECT taskId FROM agent WHERE id = ?", arguments: [agentId])
            }
            if chatId == nil {
                chatId = try Int64.fetchOne(db, sql: """
                    SELECT id FROM task WHERE projectId = ? AND closedAt IS NULL ORDER BY updatedAt DESC, id DESC LIMIT 1
                    """, arguments: [projectId])
            }
            if chatId == nil, status == "open" {
                try db.execute(sql: """
                    INSERT INTO task (projectId, title, body, source, status, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'chat', 'waitingOnYou', ?, ?)
                    """, arguments: [projectId, row["title"], row["body"], row["createdAt"], row["createdAt"]])
                chatId = db.lastInsertedRowID
            }
            guard let chatId else { continue }
            try db.execute(sql: """
                INSERT INTO chatRequest (id, projectId, taskId, runId, agentId, kind, title, body, status, response, questions, createdAt, resolvedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    row["id"], projectId, chatId, runId, agentId, row["kind"], row["title"], row["body"], status,
                    row["response"], row["questions"], row["createdAt"], row["resolvedAt"],
                ])
        }
        try db.drop(table: "inboxItem")
        try db.alter(table: "permissionRequest") { t in
            t.rename(column: "inboxItemId", to: "requestId")
        }
        try db.execute(sql: "UPDATE run SET engineState = replace(engineState, '\"inboxItemId\"', '\"requestId\"')")
    }
}
