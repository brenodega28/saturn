import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct DirectChatTests {
    func messages(_ chat: DirectChat, _ session: AgentSession) -> [DirectMessage] {
        chat.messages(with: session.agent)
    }

    @Test func aDirectMessageRecordsOnlyTheReplyToIt() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let chat = DirectChat(runtime: harness.runtime)

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        #expect(messages(chat, session).isEmpty)

        try chat.send("  Add a test for two partial refunds  ", to: session)
        try await waitUntil { messages(chat, session).contains { $0.kind == .agent } }

        let thread = messages(chat, session)
        #expect(thread.map(\.kind) == [.user, .agent])
        #expect(thread.map(\.text) == ["Add a test for two partial refunds", "Done"])
        #expect(thread.allSatisfy { !$0.awaitingReply })
    }

    @Test func messagesQueuedWhileWorkingAreAnsweredByTheJoinedTurn() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let chat = DirectChat(runtime: harness.runtime)

        let session = try await harness.spawn()
        try chat.send("Show the remaining balance", to: session)
        try chat.send("Under the amount field", to: session)
        try await waitUntil { messages(chat, session).contains { $0.kind == .agent } }
        try await waitUntil { session.agent.status == .idle }

        let thread = messages(chat, session)
        #expect(thread.map(\.kind) == [.user, .user, .agent])
        #expect(thread.allSatisfy { !$0.awaitingReply })
    }

    @Test func aReplyFromAnAgentInARunLeavesANoteInTheRequestChat() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let chat = DirectChat(runtime: harness.runtime)
        let projectId = try #require(harness.project.id)
        let task = try harness.database.insert(ProjectTask(projectId: projectId, title: "Refunds", body: "", source: .chat, status: .running, createdAt: .now, updatedAt: .now))
        let run = try harness.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "small-task", status: .running, startedAt: .now, title: "Refunds"), state: RunEngineState())

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        session.attach(toRun: try #require(run.id))
        try chat.send("Squash the migrations", to: session)
        try await waitUntil { messages(chat, session).contains { $0.kind == .agent } }

        let notes = try harness.database.leadMessages(taskId: try #require(task.id)).filter { $0.kind == .note }
        #expect(notes.map(\.text) == ["You asked Dev 1 directly: “Squash the migrations” Dev 1 replied: “Done”"])
        #expect(notes.first?.runId == run.id)
    }

    @Test func attachmentsOnlyMessagesSendImagesAndAreAnswered() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try StdinRecorder.install(in: harness)
        let chat = DirectChat(runtime: harness.runtime)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        let image = try ChatAttachment.image(data: try TestImages.encoded(width: 12, height: 12, as: .png), fileName: "shot.png")
        try chat.send("   ", attachments: [image], to: session)
        try await waitUntil { messages(chat, session).contains { $0.kind == .agent } }

        let thread = messages(chat, session)
        #expect(thread.map(\.kind) == [.user, .agent])
        #expect(thread[0].text == "")
        #expect(thread[0].chatAttachments == [image])
        #expect(thread.allSatisfy { !$0.awaitingReply })
        let sent = try #require(StdinRecorder.lines(in: harness).last)
        #expect(StdinRecorder.imageBlocks(sent).first?["source"]?["media_type"]?.string == "image/png")
    }

    @Test func pastedTextIsExpandedIntoThePromptAndStillMatchesTheReply() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try StdinRecorder.install(in: harness)
        let chat = DirectChat(runtime: harness.runtime)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        let paste = ChatAttachment.pastedText(id: UUID(), index: 1, text: String(repeating: "stack frame\n", count: 20))
        let image = try ChatAttachment.image(data: try TestImages.encoded(width: 12, height: 12, as: .png), fileName: "shot.png")
        try chat.send("Why does this crash?", attachments: [paste, image], to: session)
        try await waitUntil { messages(chat, session).contains { $0.kind == .agent } }

        let thread = messages(chat, session)
        #expect(thread[0].text == "Why does this crash?")
        #expect(thread[0].chatAttachments == [paste, image])
        #expect(thread.allSatisfy { !$0.awaitingReply })
        let sent = try #require(StdinRecorder.lines(in: harness).last)
        #expect(sent["message"]?["content"]?.array?.first?["text"]?.string == ChatAttachment.prompt(text: "Why does this crash?", attachments: [paste]))
        #expect(StdinRecorder.imageBlocks(sent).count == 1)
    }

    @Test func notesShortenLongTextToOneLine() {
        let long = String(repeating: "word ", count: 60)
        let excerpt = DirectChat.excerpt("first line\nsecond line")
        #expect(excerpt == "first line second line")
        #expect(DirectChat.excerpt(long).count == DirectChat.noteExcerptLength)
        #expect(DirectChat.excerpt(long).hasSuffix("…"))
    }
}
