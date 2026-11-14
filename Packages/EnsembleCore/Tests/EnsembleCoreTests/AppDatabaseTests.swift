import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct AppDatabaseTests {
    @Test func migratesAllTables() throws {
        let database = try AppDatabase.inMemory()
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
        }
        #expect(tables == ["agent", "chatRequest", "correction", "evidence", "leadMessage", "permissionRequest", "pin", "project", "reviewViewedFile", "run", "runStep", "task", "usage"])
    }

    @Test func chatFirstMigrationTurnsGitHubTasksIntoChatsAndDropsGitHubAndDirectMessages() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v22-permission-chat-rules")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO project (name, path, isOpen, createdAt, lastOpenedAt) VALUES ('p', '/tmp/p', 1, ?, ?)", arguments: [Date(), Date()])
            try db.execute(
                sql: "INSERT INTO task (projectId, title, source, sourceURL, externalNumber, repository, status, createdAt, updatedAt) VALUES (1, '#231 VAT rounding', 'github', 'https://github.com/acme/shop/issues/231', 231, 'acme/shop', 'incoming', ?, ?)",
                arguments: [Date(), Date()]
            )
        }

        let database = try AppDatabase(queue)

        let task = try #require(try database.task(id: 1))
        #expect(task.source == .chat)
        #expect(task.title == "#231 VAT rounding")
        let tables = try database.writer.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(!tables.contains("githubWriteBack"))
        #expect(!tables.contains("directMessage"))
        let runColumns = try database.writer.read { db in try db.columns(in: "run").map(\.name) }
        #expect(runColumns.contains("pushedAt"))
    }

    @Test func chatRequestsMigrationMovesEveryInboxItemIntoAChatAndKeepsItsID() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v23-chat-first")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO project (id, name, path, isOpen, createdAt, lastOpenedAt) VALUES (1, 'shop', '/tmp/shop', 1, ?, ?), (2, 'docs', '/tmp/docs', 1, ?, ?)", arguments: [at, at, at, at])
            try db.execute(sql: "INSERT INTO task (id, projectId, title, source, status, createdAt, updatedAt) VALUES (10, 1, 'Refunds', 'chat', 'running', ?, ?), (11, 1, 'Newest', 'chat', 'running', ?, ?)", arguments: [at, at, at, at.addingTimeInterval(60)])
            try db.execute(sql: "INSERT INTO run (id, projectId, taskId, workflow, status, costUSD, startedAt, title, workflowSnapshot, engineState) VALUES (5, 1, 10, 'w', 'waitingOnYou', 0, ?, '', '', ?)", arguments: [at, #"{"hold":{"inboxItemId":40,"message":"Approve?","reason":"approval","stepId":"approve"}}"#])
            try db.execute(sql: """
                INSERT INTO inboxItem (id, projectId, runId, kind, title, body, status, createdAt, resolvedAt) VALUES
                (40, 1, 5, 'approval', 'Approve?', '', 'open', ?, NULL),
                (41, 1, NULL, 'question', 'Old answer', '', 'resolved', ?, ?),
                (42, 2, NULL, 'notice', 'Set up checks', 'No checks yet', 'open', ?, NULL),
                (43, 2, NULL, 'notice', 'Old notice', '', 'dismissed', ?, ?)
                """, arguments: [at, at, at, at, at, at])
            try db.execute(sql: "INSERT INTO permissionRequest (projectId, agentId, capability, request, status, createdAt, inboxItemId) SELECT 1, 7, 'run_shell', 'make', 'pending', ?, 40", arguments: [at])
        }

        let database = try AppDatabase(queue)

        let requests = try database.writer.read { db in try ChatRequest.order(Column("id")).fetchAll(db) }
        #expect(requests.map(\.id) == [40, 41, 42, 43])
        #expect(requests.map(\.taskId) == [10, 11, requests[2].taskId, requests[2].taskId])
        #expect(requests.map(\.status) == [.open, .answered, .open, .dismissed])
        let startedID = try #require(requests[2].taskId)
        let started = try #require(try database.task(id: startedID))
        #expect(started.projectId == 2 && started.title == "Set up checks" && started.status == .waitingOnYou)
        #expect(try database.engineState(runId: 5).hold?.requestId == 40)
        #expect(try database.permissionRequest(requestId: 40) != nil)
        let tables = try database.writer.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(!tables.contains("inboxItem"))
    }

    @Test func reopeningAProjectUpdatesInsteadOfDuplicating() throws {
        let database = try AppDatabase.inMemory()
        let url = URL(fileURLWithPath: "/Users/me/Code/shopfront", isDirectory: true)

        let first = try database.openProject(at: url, now: Date(timeIntervalSince1970: 100))
        try database.closeProject(id: first.id!)
        #expect(try database.openProjects().isEmpty)

        let second = try database.openProject(at: url, now: Date(timeIntervalSince1970: 200))

        #expect(second.id == first.id)
        #expect(second.name == "shopfront")
        #expect(try database.openProjects().map(\.id) == [first.id])
        #expect(try database.recentProjects().first?.lastOpenedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func ordersRecentProjectsByLastOpened() throws {
        let database = try AppDatabase.inMemory()
        try database.openProject(at: URL(fileURLWithPath: "/a"), now: Date(timeIntervalSince1970: 1))
        try database.openProject(at: URL(fileURLWithPath: "/b"), now: Date(timeIntervalSince1970: 3))
        try database.openProject(at: URL(fileURLWithPath: "/c"), now: Date(timeIntervalSince1970: 2))

        #expect(try database.recentProjects().map(\.name) == ["b", "c", "a"])
        #expect(try database.recentProjects(limit: 1).map(\.name) == ["b"])
        #expect(try database.openProjects().map(\.name) == ["a", "b", "c"])
    }

    @Test func persistsTheFullRecordGraphAndCascadesOnForget() throws {
        let database = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        let project = try database.openProject(at: URL(fileURLWithPath: "/repo"), now: now)
        let projectId = try #require(project.id)

        try database.writer.write { db in
            var task = ProjectTask(projectId: projectId, title: "Refunds v2", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now)
            try task.insert(db)
            var run = Run(projectId: projectId, taskId: task.id!, workflow: "feature-delivery", status: .running, startedAt: now)
            try run.insert(db)
            var agent = Agent(projectId: projectId, runId: run.id, role: "django-developer", name: "Django Dev 1", worktreePath: "/repo/.crew/django-dev-1", branch: "crew/django-dev-1/refunds", status: .working, createdAt: now, updatedAt: now)
            try agent.insert(db)
            var usage = UsageEntry(projectId: projectId, runId: run.id, agentId: agent.id, model: "claude-sonnet-5-5", inputTokens: 1_200, outputTokens: 300, costUSD: 0.42, recordedAt: now)
            try usage.insert(db)
        }

        let agent = try database.writer.read { db in try Agent.fetchOne(db) }
        #expect(agent?.status == .working)
        #expect(agent?.branch == "crew/django-dev-1/refunds")
        #expect(try database.spend(since: now) == 0.42)
        #expect(try database.spend(since: now.addingTimeInterval(1)) == 0)

        try database.forgetProject(id: projectId)

        let counts = try database.writer.read { db in
            try [ProjectTask.fetchCount(db), Run.fetchCount(db), Agent.fetchCount(db), UsageEntry.fetchCount(db)]
        }
        #expect(counts == [0, 0, 0, 0])
    }

    @Test func agentNamesAreUniquePerProject() throws {
        let database = try AppDatabase.inMemory()
        let now = Date()
        let projectId = try #require(try database.openProject(at: URL(fileURLWithPath: "/repo")).id)

        try database.writer.write { db in
            var agent = Agent(projectId: projectId, role: "qa", name: "QA", status: .idle, createdAt: now, updatedAt: now)
            try agent.insert(db)
        }
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                var duplicate = Agent(projectId: projectId, role: "qa", name: "QA", status: .idle, createdAt: now, updatedAt: now)
                try duplicate.insert(db)
            }
        }
    }

    @Test func survivesReopeningFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ensemble-db-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "ensemble.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let database = try AppDatabase.open(at: url)
            try database.openProject(at: URL(fileURLWithPath: "/repo"))
        }

        let reopened = try AppDatabase.open(at: url)
        #expect(try reopened.openProjects().map(\.path) == ["/repo"])
    }
}
