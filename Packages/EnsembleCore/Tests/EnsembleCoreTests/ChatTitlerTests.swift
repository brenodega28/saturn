import Foundation
import Testing
@testable import EnsembleCore

@Suite struct ChatTitleCleaningTests {
    @Test(arguments: [
        ("Fix checkout refund rounding", "Fix checkout refund rounding"),
        ("\"Fix checkout refund rounding\"", "Fix checkout refund rounding"),
        ("“Fix checkout refund rounding”", "Fix checkout refund rounding"),
        ("'Fix refunds'", "Fix refunds"),
        ("**Fix checkout refunds**", "Fix checkout refunds"),
        ("# Fix `refund` rounding", "Fix refund rounding"),
        ("Title: Fix checkout refunds", "Fix checkout refunds"),
        ("title: \"Fix checkout refunds.\"", "Fix checkout refunds"),
        ("Fix checkout refunds!?", "Fix checkout refunds"),
        ("Fix checkout refunds;", "Fix checkout refunds"),
        ("\n\n  Fix checkout refunds\nBecause the user asked", "Fix checkout refunds"),
    ])
    func cleansTheReply(reply: String, title: String) {
        #expect(ChatTitler.cleanTitle(reply) == title)
    }

    @Test func capsAnOverlongReply() throws {
        let title = try #require(ChatTitler.cleanTitle(String(repeating: "word ", count: 40)))
        #expect(title.count <= LeadRequest.maxTitleLength)
        #expect(title.hasSuffix("…"))
    }

    @Test(arguments: ["", "   \n\n", "\"\"", "**", "Title:", "..."])
    func anEmptyReplyGivesNoTitle(reply: String) {
        #expect(ChatTitler.cleanTitle(reply) == nil)
    }

    @Test func thePromptCarriesAtMostTwoThousandCharactersOfTheRequest() {
        let prompt = ChatTitler.prompt(for: String(repeating: "a", count: 5000) + "TAIL")
        #expect(prompt.contains(String(repeating: "a", count: 2000)))
        #expect(!prompt.contains(String(repeating: "a", count: 2001)))
        #expect(!prompt.contains("TAIL"))
    }

    @Test func renamingIfUntitledKeepsAManualRename() throws {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shop-\(UUID().uuidString)"))
        let chat = try database.insert(Chat(projectId: try #require(project.id), title: "Fix the refunds", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now))
        let id = try #require(chat.id)

        try database.renameChat(id: id, to: "My refunds")
        #expect(try !database.renameChatIfUntitled(id: id, from: "Fix the refunds", to: "Refund rounding fix"))
        #expect(try database.task(id: id)?.title == "My refunds")

        #expect(try database.renameChatIfUntitled(id: id, from: "My refunds", to: "Refund rounding fix"))
        #expect(try database.task(id: id)?.title == "Refund rounding fix")
    }
}

@MainActor
@Suite(.serialized) struct ChatTitlerTests {
    typealias Setup = WorkflowDriverTests.Setup

    func makeChat(timeout: Duration = .seconds(20)) async throws -> (Setup, LeadChat) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let titler = ChatTitler(runtime: setup.harness.runtime, timeout: timeout)
        return (setup, LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver, titler: titler))
    }

    func reply(_ title: String, in setup: Setup) throws {
        try title.write(to: setup.harness.bin.appending(path: "title"), atomically: true, encoding: .utf8)
    }

    func titleCalls(_ setup: Setup) -> [String] {
        ((try? String(contentsOf: setup.harness.bin.appending(path: "titles.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func title(of chat: Chat, _ setup: Setup) -> String? {
        (try? setup.harness.database.task(id: chat.id!))??.title
    }

    @Test func aNewChatGetsTheGeneratedTitle() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try reply("\"Repo contents overview.\"\n", in: setup)

        let task = try await chat.createRequest("CHAT what is in this repo?", in: setup.project)
        #expect(task.title == "CHAT what is in this repo?")
        try await waitUntil { title(of: task, setup) == "Repo contents overview" }

        let call = try #require(titleCalls(setup).first)
        #expect(call.contains("--model haiku"))
        #expect(call.contains("--no-session-persistence"))
        #expect(call.contains("--strict-mcp-config"))
        #expect(call.contains("CHAT what is in this repo?"))
        #expect(!call.contains("stream-json"))
        #expect(!setup.harness.launches().contains { $0.contains("--output-format text") })
    }

    @Test func laterMessagesDoNotRetitleTheChat() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try reply("Repo contents overview", in: setup)
        let task = try await chat.createRequest("CHAT what is in this repo?", in: setup.project)
        try await waitUntil { title(of: task, setup) == "Repo contents overview" }

        try reply("Something else entirely", in: setup)
        try await chat.send("CHAT and the tests?", to: task, in: setup.project)
        try await Task.sleep(for: .milliseconds(300))

        #expect(titleCalls(setup).count == 1)
        #expect(title(of: task, setup) == "Repo contents overview")
    }

    @Test func pastedTextTitlesAnAttachmentOnlyChat() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try reply("Stack trace triage", in: setup)

        let task = try await chat.createRequest("", attachments: [.pastedText(id: UUID(), index: 1, text: "CHAT Fatal error: index out of range")], in: setup.project)
        try await waitUntil { title(of: task, setup) == "Stack trace triage" }
        #expect(titleCalls(setup).first?.contains("Fatal error: index out of range") == true)
    }

    @Test func anImageOnlyChatKeepsItsPlaceholder() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try reply("Should not be used", in: setup)

        let image = ChatAttachment.image(id: UUID(), mediaType: "image/png", fileName: "shot.png", data: Data([1]))
        let task = try await chat.createRequest("", attachments: [image], in: setup.project)
        try await Task.sleep(for: .milliseconds(300))

        #expect(titleCalls(setup).isEmpty)
        #expect(title(of: task, setup) == "Image")
    }

    @Test(arguments: ["fail", "empty", "slow"])
    func aFailingTitlerLeavesThePlaceholder(mode: String) async throws {
        let (setup, chat) = try await makeChat(timeout: .milliseconds(500))
        defer { setup.harness.cleanUp() }
        if mode == "empty" { try reply("  \n", in: setup) } else { try reply("Late title", in: setup) }
        try mode.write(to: setup.harness.bin.appending(path: "title-mode"), atomically: true, encoding: .utf8)

        let task = try await chat.createRequest("CHAT what is in this repo?", in: setup.project)
        try await waitUntil { titleCalls(setup).count == 1 }
        try await Task.sleep(for: .seconds(1))

        #expect(title(of: task, setup) == "CHAT what is in this repo?")
    }

    @Test func aMissingExecutableLeavesThePlaceholder() async throws {
        let (setup, _) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let task = try setup.harness.database.insert(Chat(projectId: setup.project.id!, title: "Fix it", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now))
        let titler = ChatTitler(database: setup.harness.database) {
            ChatTitler.Launch(executable: URL(fileURLWithPath: "/nonexistent/claude"), environment: [:])
        }

        await titler.generateTitle(for: task, text: "Fix the refunds")

        #expect(title(of: task, setup) == "Fix it")
    }

    @Test func aManualRenameBeforeTheTitleArrivesWins() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        try reply("Repo contents overview", in: setup)

        let task = try await chat.createRequest("CHAT what is in this repo?", in: setup.project)
        try setup.harness.database.renameChat(id: task.id!, to: "My chat")
        await chat.titler.generateTitle(for: task, text: "CHAT what is in this repo?")

        #expect(title(of: task, setup) == "My chat")
    }
}
