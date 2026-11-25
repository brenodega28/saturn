import Foundation
import Testing
@testable import SaturnCore

@MainActor
struct PendingPermissionCountsTests {
    struct Fixture {
        let database: AppDatabase
        let projectId: Int64
        let otherProjectId: Int64

        func task(in projectId: Int64? = nil) throws -> Int64 {
            let task = try database.insert(Chat(
                projectId: projectId ?? self.projectId, title: "T", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now
            ))
            return try #require(task.id)
        }

        @discardableResult
        func card(taskId: Int64, in projectId: Int64? = nil, status: PermissionCardStatus? = .pending, kind: LeadMessageKind = .permission) throws -> LeadMessage {
            try database.insert(LeadMessage(
                projectId: projectId ?? self.projectId, taskId: taskId, kind: kind, text: "npm install", title: "Dev 1",
                createdAt: .now, permissionStatus: status, capability: .installPackages
            ))
        }
    }

    func makeFixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/pending-a-\(UUID().uuidString)"))
        let other = try database.openProject(at: URL(fileURLWithPath: "/tmp/pending-b-\(UUID().uuidString)"))
        return Fixture(database: database, projectId: try #require(project.id), otherProjectId: try #require(other.id))
    }

    @Test func countsOnlyPendingPermissionCardsPerTask() throws {
        let f = try makeFixture()
        let busy = try f.task()
        let quiet = try f.task()
        let answered = try f.task()
        try f.card(taskId: busy)
        try f.card(taskId: busy)
        try f.card(taskId: busy, status: .denied)
        try f.card(taskId: quiet, status: nil, kind: .lead)
        try f.card(taskId: answered, status: .allowedOnce)
        try f.card(taskId: answered, status: .allowedForRun)

        #expect(try f.database.pendingPermissionCounts(projectId: f.projectId) == [busy: 2])
    }

    @Test func scopesCountsToTheProject() throws {
        let f = try makeFixture()
        let mine = try f.task()
        let theirs = try f.task(in: f.otherProjectId)
        try f.card(taskId: mine)
        try f.card(taskId: theirs, in: f.otherProjectId)
        try f.card(taskId: theirs, in: f.otherProjectId)

        #expect(try f.database.pendingPermissionCounts(projectId: f.projectId) == [mine: 1])
        #expect(try f.database.pendingPermissionCounts(projectId: f.otherProjectId) == [theirs: 2])
        let all = try f.database.pendingPermissionCounts()
        #expect(all.count(projectId: f.projectId) == 1 && all.count(projectId: f.otherProjectId) == 2)
        #expect(all.count(taskId: theirs) == 2 && all.count(taskId: -1) == 0)
    }

    @Test func ignoresClosedRequests() throws {
        let f = try makeFixture()
        let open = try f.task()
        let closed = try f.task()
        try f.card(taskId: open)
        try f.card(taskId: closed)
        try f.database.setClosed(taskId: closed, reason: .done, at: .now)

        #expect(try f.database.pendingPermissionCounts(projectId: f.projectId) == [open: 1])
        #expect(try f.database.pendingPermissionCounts().count(projectId: f.projectId) == 1)
    }

    @Test func emptyProjectHasNoCounts() throws {
        let f = try makeFixture()
        _ = try f.task()

        #expect(try f.database.pendingPermissionCounts(projectId: f.projectId).isEmpty)
        #expect(try f.database.pendingPermissionCounts() == PendingPermissionCounts())
    }

    @Test func feedFollowsCardsAsTheyAreCreatedAndAnswered() async throws {
        let f = try makeFixture()
        let taskId = try f.task()
        let feed = PendingPermissionFeed(database: f.database)
        feed.start()
        defer { feed.stop() }
        #expect(feed.count(taskId: taskId) == 0)

        var card = try f.card(taskId: taskId)
        try await waitUntil { feed.count(taskId: taskId) == 1 }
        #expect(feed.count(projectId: f.projectId) == 1)

        card.permissionStatus = .allowedOnce
        try f.database.save(card)
        try await waitUntil { feed.count(taskId: taskId) == 0 }
        #expect(feed.count(projectId: f.projectId) == 0)
    }
}
