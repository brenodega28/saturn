import Foundation
import Testing
@testable import EnsembleCore

@MainActor
struct ChatDraftStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)", directoryHint: .isDirectory)

    func makeStore() -> ChatDraftStore {
        ChatDraftStore(directory: directory)
    }

    @Test func numbersNewDraftsWithTheLowestUnusedNumber() {
        let store = makeStore()
        let first = store.createNewDraft(projectID: 1)
        let second = store.createNewDraft(projectID: 2)
        let third = store.createNewDraft(projectID: 1)
        #expect([first, second, third].map(\.number) == [1, 2, 3])

        store.deleteNewDraft(id: first.id)
        let next = store.createNewDraft(projectID: 1)

        #expect(next.number == 1)
        #expect(next.title == "New chat 1")
        #expect(store.createNewDraft(projectID: 1).number == 4)
    }

    @Test func draftsWithAttachmentsSurviveANewStore() throws {
        let store = makeStore()
        let image = ChatAttachment.image(id: UUID(), mediaType: "image/png", fileName: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        let paste = ChatAttachment.pastedText(id: UUID(), index: 1, text: "line one\nline two")
        let draft = store.createNewDraft(projectID: 7)
        store.updateNewDraft(id: draft.id, with: PendingMessage(text: "Fix the login bug", attachments: [image, paste]))
        store.flush()

        let reloaded = makeStore()
        let loaded = try #require(reloaded.newDraft(id: draft.id))

        #expect(loaded.projectID == 7)
        #expect(loaded.number == draft.number)
        #expect(loaded.text == "Fix the login bug")
        #expect(loaded.attachments == [image, paste])
        #expect(reloaded.newDrafts().map(\.id) == [draft.id])
    }

    @Test func coalescesSavesUntilFlushed() {
        let store = makeStore()
        let draft = store.createNewDraft(projectID: 1)
        store.updateNewDraft(id: draft.id, with: PendingMessage(text: "typing"))

        #expect(makeStore().newDraft(id: draft.id)?.text == "")

        store.flush()

        #expect(makeStore().newDraft(id: draft.id)?.text == "typing")
    }

    @Test func deleteRemovesTheFile() {
        let store = makeStore()
        let draft = store.createNewDraft(projectID: 1)
        let file = store.newDraftURL(id: draft.id)
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.updateNewDraft(id: draft.id, with: PendingMessage(text: "unsaved"))
        store.deleteNewDraft(id: draft.id)
        store.flush()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.newDraft(id: draft.id) == nil)
        #expect(makeStore().newDrafts().isEmpty)
    }

    @Test func setsGetsAndClearsChatDrafts() {
        let store = makeStore()
        let paste = ChatAttachment.pastedText(id: UUID(), index: 1, text: "log output")
        let message = PendingMessage(text: "half typed", attachments: [paste])

        store.setChatDraft(message, chatID: 42)
        store.flush()

        #expect(store.chatDraft(chatID: 42) == message)
        #expect(makeStore().chatDraft(chatID: 42) == message)
        #expect(store.chatDraft(chatID: 43) == nil)

        store.clearChatDraft(chatID: 42)
        store.flush()

        #expect(store.chatDraft(chatID: 42) == nil)
        #expect(makeStore().chatDraft(chatID: 42) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.chatDraftURL(chatID: 42).path))
    }

    @Test func settingAnEmptyChatDraftClearsIt() {
        let store = makeStore()
        store.setChatDraft(PendingMessage(text: "x"), chatID: 1)
        store.setChatDraft(PendingMessage(text: ""), chatID: 1)
        store.flush()

        #expect(store.chatDraft(chatID: 1) == nil)
        #expect(makeStore().chatDraft(chatID: 1) == nil)
    }
}
