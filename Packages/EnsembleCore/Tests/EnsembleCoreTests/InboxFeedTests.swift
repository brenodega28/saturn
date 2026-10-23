import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct InboxFeedTests {
    let database: AppDatabase
    let alpha: Project
    let beta: Project
    let launch = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        database = try AppDatabase.inMemory()
        alpha = try database.openProject(at: URL(fileURLWithPath: "/tmp/alpha-\(UUID().uuidString)"))
        beta = try database.openProject(at: URL(fileURLWithPath: "/tmp/beta-\(UUID().uuidString)"))
    }

    @discardableResult
    func item(_ project: Project, _ kind: InboxKind, minutes: Double, status: InboxStatus = .open) throws -> InboxItem {
        try database.createInboxItem(InboxItem(
            projectId: try #require(project.id), kind: kind, title: "\(kind.rawValue) \(minutes)", status: status,
            createdAt: launch.addingTimeInterval(minutes * 60)
        ))
    }

    @Test func countsOnlyOpenItemsInOpenProjects() throws {
        try item(alpha, .question, minutes: 1)
        try item(alpha, .notice, minutes: 2, status: .dismissed)
        try item(beta, .planApproval, minutes: 3)
        try item(beta, .failure, minutes: 4, status: .resolved)
        #expect(try database.openInboxCount() == 2)

        try database.closeProject(id: try #require(beta.id))
        #expect(try database.openInboxCount() == 1)
        #expect(try database.openInboxItemsInOpenProjects().map(\.kind) == [.question])
    }

    @Test func groupsByProjectNewestFirst() throws {
        try item(alpha, .question, minutes: 1)
        try item(beta, .approval, minutes: 2)
        try item(alpha, .budget, minutes: 3)

        let groups = InboxFeed.group(try database.openInboxItemsInOpenProjects(), projects: [alpha, beta])

        #expect(groups.map(\.project.id) == [alpha.id, beta.id])
        #expect(groups[0].items.map(\.kind) == [.budget, .question])
        #expect(groups[1].items.map(\.kind) == [.approval])
    }

    @Test func liveFeedTracksChangesAndOnlyAnnouncesItemsCreatedAfterLaunch() async throws {
        try item(alpha, .question, minutes: -5)
        let feed = InboxFeed(database: database, launchedAt: launch)
        var announced: [InboxKind] = []
        feed.onNewItems = { announced += $0.map(\.kind) }
        feed.start()
        #expect(feed.count == 1)
        #expect(announced.isEmpty)

        let approval = try item(beta, .planApproval, minutes: 1)
        try await waitUntil { feed.count == 2 }
        #expect(announced == [.planApproval])
        #expect(feed.items.first?.id == approval.id)

        try database.resolveInboxItem(id: try #require(approval.id), response: "approved")
        try await waitUntil { feed.count == 1 }
        #expect(announced == [.planApproval])
        #expect(feed.items(inProject: try #require(alpha.id)).count == 1)
        feed.stop()
    }
}
