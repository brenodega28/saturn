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
        #expect(tables == ["agent", "correction", "directMessage", "evidence", "githubWriteBack", "inboxItem", "leadMessage", "permissionRequest", "pin", "project", "reviewViewedFile", "run", "runStep", "task", "usage"])
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
