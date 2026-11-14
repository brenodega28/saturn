import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct ChatRequestFeedTests {
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
    func item(_ project: Project, _ kind: ChatRequestKind, minutes: Double, status: ChatRequestState = .open) throws -> ChatRequest {
        try database.createChatRequest(ChatRequest(
            projectId: try #require(project.id), kind: kind, title: "\(kind.rawValue) \(minutes)", status: status,
            createdAt: launch.addingTimeInterval(minutes * 60)
        ))
    }

    @Test func countsOnlyOpenItemsInOpenProjects() throws {
        try item(alpha, .question, minutes: 1)
        try item(alpha, .notice, minutes: 2, status: .dismissed)
        try item(beta, .planApproval, minutes: 3)
        try item(beta, .failure, minutes: 4, status: .answered)
        #expect(try database.openChatRequestCount() == 2)

        try database.closeProject(id: try #require(beta.id))
        #expect(try database.openChatRequestCount() == 1)
        #expect(try database.openChatRequestsInOpenProjects().map(\.kind) == [.question])
    }

    func chat(_ project: Project, _ title: String, minutes: Double, closed: Bool = false) throws -> ProjectTask {
        let at = launch.addingTimeInterval(minutes * 60)
        return try database.insert(ProjectTask(
            projectId: try #require(project.id), title: title, body: "", source: .chat, status: .running,
            closedAt: closed ? at : nil, createdAt: at, updatedAt: at
        ))
    }

    @Test func aRequestFromARunJoinsThatRunsChat() throws {
        let refunds = try chat(alpha, "Refunds v2", minutes: 1)
        try chat(alpha, "Newer chat", minutes: 2)
        let run = try database.insert(Run(projectId: try #require(alpha.id), taskId: try #require(refunds.id), workflow: "w", status: .running, startedAt: launch), state: RunEngineState())

        let request = try database.createChatRequest(ChatRequest(projectId: try #require(alpha.id), runId: run.id, kind: .question, title: "Squash?", createdAt: launch))

        #expect(request.taskId == refunds.id)
        #expect(try database.chatRequests(taskId: try #require(refunds.id)).map(\.title) == ["Squash?"])
    }

    @Test func aRequestWithoutARunJoinsTheNewestOpenChat() throws {
        let older = try chat(alpha, "Older", minutes: 1)
        let newest = try chat(alpha, "Newest", minutes: 3)
        try chat(alpha, "Closed", minutes: 5, closed: true)

        let request = try database.createChatRequest(ChatRequest(projectId: try #require(alpha.id), kind: .notice, title: "Set up checks", createdAt: launch))

        #expect(request.taskId == newest.id)
        #expect(request.taskId != older.id)
    }

    @Test func aRequestInAProjectWithNoOpenChatStartsOne() throws {
        try chat(alpha, "Closed", minutes: 1, closed: true)

        let request = try database.createChatRequest(ChatRequest(projectId: try #require(alpha.id), kind: .budget, title: "Budget reached", body: "Raise the limit?", createdAt: launch))

        let createdID = try #require(request.taskId)
        let created = try #require(try database.task(id: createdID))
        #expect(created.title == "Budget reached")
        #expect(created.body == "Raise the limit?")
        #expect(created.status == .waitingOnYou)
        #expect(!created.isClosed)
    }

    @Test func liveFeedTracksChangesAndOnlyAnnouncesItemsCreatedAfterLaunch() async throws {
        try item(alpha, .question, minutes: -5)
        let feed = ChatRequestFeed(database: database, launchedAt: launch)
        var announced: [ChatRequestKind] = []
        feed.onNewItems = { announced += $0.map(\.kind) }
        feed.start()
        #expect(feed.count == 1)
        #expect(announced.isEmpty)

        let approval = try item(beta, .planApproval, minutes: 1)
        try await waitUntil { feed.count == 2 }
        #expect(announced == [.planApproval])
        #expect(feed.items.first?.id == approval.id)

        try database.resolveChatRequest(id: try #require(approval.id), response: "approved")
        try await waitUntil { feed.count == 1 }
        #expect(announced == [.planApproval])
        #expect(feed.items(inProject: try #require(alpha.id)).count == 1)
        feed.stop()
    }
}
