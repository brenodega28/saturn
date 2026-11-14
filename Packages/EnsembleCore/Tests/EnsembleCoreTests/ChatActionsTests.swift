import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct ChatActionsTests {
    let database: AppDatabase
    let project: Project
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        database = try AppDatabase.inMemory()
        project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shop-\(UUID().uuidString)"))
    }

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    func chat(_ title: String = "Refunds v2") throws -> Chat {
        try database.insert(Chat(projectId: try #require(project.id), title: title, body: "", source: .chat, status: .running, createdAt: at(0), updatedAt: at(0)))
    }

    @Test func renamingTrimsTheTitleAndRefusesAnEmptyOne() throws {
        let id = try #require(try chat().id)

        let renamed = try database.renameChat(id: id, to: "  Refunds, partial too ", now: at(1))

        #expect(renamed.title == "Refunds, partial too")
        #expect(throws: ChatActionError.emptyTitle) { try database.renameChat(id: id, to: "   ") }
        #expect(try database.task(id: id)?.title == "Refunds, partial too")
    }

    @Test func lastActivityIgnoresYourOwnMessagesAndCountsTheLeadRunsAndRequests() throws {
        let id = try #require(try chat().id)
        let projectID = try #require(project.id)
        try database.insert(LeadMessage(projectId: projectID, taskId: id, kind: .user, text: "Hi", createdAt: at(9)))
        try database.insert(LeadMessage(projectId: projectID, taskId: id, kind: .lead, text: "Hello", createdAt: at(2)))
        try database.createChatRequest(ChatRequest(projectId: projectID, taskId: id, kind: .question, title: "Squash?", createdAt: at(4)))

        #expect(try database.lastActivity(projectId: projectID)[id] == at(4))
    }

    @Test func aChatIsUnreadUntilViewedAfterItsLastActivity() throws {
        #expect(ChatActivity.isUnread(viewedAt: nil, createdAt: at(0), lastActivity: at(1)))
        #expect(!ChatActivity.isUnread(viewedAt: at(2), createdAt: at(0), lastActivity: at(1)))
        #expect(ChatActivity.isUnread(viewedAt: at(2), createdAt: at(0), lastActivity: at(3)))
        #expect(!ChatActivity.isUnread(viewedAt: nil, createdAt: at(0), lastActivity: nil))

        let id = try #require(try chat().id)
        try database.markViewed(chatId: id, at: at(5))
        #expect(try database.task(id: id)?.viewedAt == at(5))
    }

    @Test func deletingAChatRemovesItsRunsRequestsAndMessages() throws {
        let id = try #require(try chat().id)
        let projectID = try #require(project.id)
        let run = try database.insert(Run(projectId: projectID, taskId: id, workflow: "w", status: .succeeded, startedAt: at(1)), state: RunEngineState())
        try database.createChatRequest(ChatRequest(projectId: projectID, runId: run.id, kind: .question, title: "Q", createdAt: at(2)))
        try database.insert(LeadMessage(projectId: projectID, taskId: id, kind: .lead, text: "Hello", createdAt: at(2)))

        try database.deleteChat(id: id)

        #expect(try database.task(id: id) == nil)
        #expect(try database.runs(taskId: id).isEmpty)
        #expect(try database.chatRequests(taskId: id).isEmpty)
        #expect(try database.leadMessages(taskId: id).isEmpty)
    }

    @Test func theLeadModelAndEffortArePerChat() throws {
        let id = try #require(try chat().id)

        try database.setLead(model: "sonnet", effort: .high, chatId: id)

        let stored = try #require(try database.task(id: id))
        #expect(stored.leadModel == "sonnet")
        #expect(stored.leadEffort == .high)
    }
}
