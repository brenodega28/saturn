import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct ChatStatusTests {
    typealias Setup = WorkflowDriverTests.Setup

    func makeChat() async throws -> (Setup, LeadChat) {
        let (setup, chat, _) = try await LeadChatTests().makeChat()
        return (setup, chat)
    }

    func messages(_ setup: Setup, _ task: Chat) -> [LeadMessage] {
        (try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []
    }

    func stored(_ setup: Setup, _ task: Chat) throws -> Chat {
        try #require(try setup.harness.database.task(id: task.id!))
    }

    func toolLog(_ setup: Setup) -> String {
        (try? String(contentsOf: setup.harness.bin.appending(path: "mcp.log"), encoding: .utf8)) ?? ""
    }

    func lead(_ setup: Setup, _ task: Chat) throws -> Agent {
        try #require(try setup.harness.database.leadAgent(taskId: task.id!))
    }

    func quietChat(_ setup: Setup, _ chat: LeadChat) async throws -> Chat {
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let session = try #require(setup.harness.runtime.session(for: try lead(setup, task)))
        try await waitUntil { !session.isRunning }
        return task
    }

    func chatWithBuilder(_ setup: Setup, _ chat: LeadChat) async throws -> (Chat, AgentSession) {
        let (task, run) = try await LeadChatTests().startedRun(setup, chat)
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
        let builder = try await setup.harness.runtime.createRunAgent(
            in: setup.project, kind: .builder, runId: run.id!, runStepId: nil, task: "Add alpha", git: setup.harness.repo.git
        )
        let session = try #require(setup.harness.runtime.session(for: try lead(setup, task)))
        try await waitUntil { !session.isRunning }
        return (task, builder)
    }

    func setStatus(_ status: String, _ setup: Setup, _ chat: LeadChat, _ task: Chat) async throws {
        let replies = messages(setup, task).filter { $0.kind == .lead }.count
        try await chat.send("CHAT-STATUS \(status)", to: try stored(setup, task), in: setup.project)
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count > replies }
    }

    @Test func finishedKeepsEveryAgentWorktreeAndBranch() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, builder) = try await chatWithBuilder(setup, chat)
        let agentIDs = try setup.harness.database.requestAgents(taskId: task.id!).map(\.id)
        let worktree = try #require(builder.agent.worktreeURL)

        try await setStatus("finished", setup, chat, task)
        let session = try #require(setup.harness.runtime.session(for: try lead(setup, task)))
        try await waitUntil { !session.isRunning }

        let finished = try stored(setup, task)
        #expect(finished.isFinished && finished.finishedAt != nil && !finished.isClosed)
        #expect(ChatStage.of(ChatStage.Facts(isFinished: finished.isFinished)) == .finished)
        let requests = try setup.harness.database.leadRequests(projectId: setup.project.id!)
        #expect(LeadRequest.partition(requests).open.map(\.id) == [task.id])
        #expect(try setup.harness.database.requestAgents(taskId: task.id!).map(\.id) == agentIDs)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await LeadChatTests().branchExists(setup, try #require(builder.agent.branch)))
        #expect(messages(setup, task).contains { $0.kind == .note && $0.text == "Lead marked this chat Finished — Tests pass" })
        #expect(toolLog(setup).contains("marked Finished"))
    }

    @Test func resolvedAndClosedCloseTheChatAndCleanUpAfterTheLeadsTurn() async throws {
        for (status, reason) in [("resolved", RequestCloseReason.done), ("closed", .dropped)] {
            let (setup, chat) = try await makeChat()
            defer { setup.harness.cleanUp() }
            let (task, builder) = try await chatWithBuilder(setup, chat)
            let agentIDs = try setup.harness.database.requestAgents(taskId: task.id!).map(\.id)
            let worktree = try #require(builder.agent.worktreeURL)
            let branch = try #require(builder.agent.branch)

            try await setStatus(status, setup, chat, task)

            let closed = try stored(setup, task)
            #expect(closed.isClosed && closed.closeReason == reason && closed.finishedAt == nil)
            #expect(ChatStage.of(ChatStage.Facts(closeReason: closed.closeReason, isClosed: true)).rawValue == (reason == .done ? "done" : "dropped"))
            #expect(messages(setup, task).last { $0.kind == .lead }?.text == "Status set.")
            #expect(toolLog(setup).contains("deleted after your turn ends"))
            #expect(!toolLog(setup).contains("isError\":true"))
            try await waitUntil { (try? setup.harness.database.requestAgents(taskId: task.id!).isEmpty) == true }
            try LeadChatTests().expectDeleted(setup, agentIDs)
            #expect(!FileManager.default.fileExists(atPath: worktree.path))
            #expect(try await !LeadChatTests().branchExists(setup, branch))
            #expect(setup.driver.closingTasks.isEmpty)
        }
    }

    @Test func openClearsFinishedResolvedAndClosed() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await quietChat(setup, chat)
        let leadID = try #require(try lead(setup, task).id)
        let database = setup.harness.database

        for mark in [{ try database.setFinished(taskId: task.id!, at: .now) }, { try database.setClosed(taskId: task.id!, reason: .done, at: .now) }, { try database.setClosed(taskId: task.id!, reason: .dropped, at: .now) }] {
            _ = try mark()
            let reply = try await setup.driver.receive(.setChatStatus(.open, reason: nil), from: leadID)
            let open = try stored(setup, task)
            #expect(reply.contains("Open"))
            #expect(open.finishedAt == nil && open.closedAt == nil && open.closeReason == nil)
        }
        #expect(try lead(setup, task).id == leadID)
        #expect(messages(setup, task).filter { $0.kind == .note }.map(\.text) == Array(repeating: "Lead marked this chat Open", count: 3))
    }

    @Test func closingAFinishedChatClearsFinishedAt() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await quietChat(setup, chat)
        let leadID = try #require(try lead(setup, task).id)

        _ = try await setup.driver.receive(.setChatStatus(.finished, reason: nil), from: leadID)
        #expect(try stored(setup, task).isFinished)
        _ = try await setup.driver.receive(.setChatStatus(.resolved, reason: "Shipped"), from: leadID)

        let resolved = try stored(setup, task)
        #expect(resolved.closeReason == .done && resolved.finishedAt == nil)
        #expect(setup.driver.closingTasks == [task.id!])
        #expect(try lead(setup, task).id == leadID)
    }

    @Test func finishedResolvedAndClosedAreRefusedWhileARunIsActive() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let (task, run) = try await LeadChatTests().startedRun(setup, chat)
        let leadID = try #require(try lead(setup, task).id)

        for status in [ChatStatusTarget.finished, .resolved, .closed] {
            do {
                _ = try await setup.driver.receive(.setChatStatus(status, reason: nil), from: leadID)
                Issue.record("\(status) was not refused")
            } catch let error as HandoffError {
                #expect(error.localizedDescription.contains("run for this request is still going"))
            }
        }
        let current = try stored(setup, task)
        #expect(!current.isClosed && !current.isFinished)
        #expect(setup.driver.closingTasks.isEmpty)
        #expect(try await setup.driver.receive(.setChatStatus(.open, reason: nil), from: leadID).contains("Open"))
        try await setup.engine.cancel(try #require(setup.engine.runs[run.id!]))
    }

    @Test func anUnknownStatusNamesTheFourStatuses() throws {
        #expect(throws: HandoffError.notAllowed("Unknown status “done”. Use one of: open, finished, resolved, closed.")) {
            try HandoffTool.setChatStatus.decode(.object(["status": .string("done")]))
        }
        #expect(throws: HandoffError.missing("status")) { try HandoffTool.setChatStatus.decode(.object([:])) }
        #expect(try HandoffTool.setChatStatus.decode(.object(["status": .string(" Finished "), "reason": .string("  ")])) == .setChatStatus(.finished, reason: nil))
    }

    @Test func onlyARequestsLeadGetsTheTool() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await quietChat(setup, chat)
        let requestLead = try lead(setup, task)
        #expect(setup.driver.tools(for: requestLead).contains(.setChatStatus))
        #expect(setup.harness.launches().last?.contains("mcp__saturn__set_chat_status") == true)

        var projectLead = requestLead
        projectLead.taskId = nil
        #expect(!setup.driver.tools(for: projectLead).contains(.setChatStatus))
        var builder = requestLead
        builder.role = AgentKind.builder.rawValue
        #expect(!setup.driver.tools(for: builder).contains(.setChatStatus))
    }

    @Test func aUserMessageReturnsAFinishedOrClosedChatToOpen() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await quietChat(setup, chat)
        let database = setup.harness.database

        for mark in [{ try database.setFinished(taskId: task.id!, at: .now) }, { try database.setClosed(taskId: task.id!, reason: .dropped, at: .now) }] {
            _ = try mark()
            try await chat.send("CHAT again", to: try stored(setup, task), in: setup.project)
            let open = try stored(setup, task)
            #expect(open.finishedAt == nil && open.closedAt == nil && open.closeReason == nil)
        }
    }

    @Test func theUserCanFinishAndReopenAChat() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try await quietChat(setup, chat)

        #expect(try chat.finish(task).isFinished)
        let reopened = try chat.reopen(try stored(setup, task))
        #expect(!reopened.isFinished && !reopened.isClosed)
    }
}
