import Foundation
import Testing
@testable import SaturnCore

@MainActor
struct PendingMessageTests {
    let returns = ReturnedMessages<String>()

    @Test func returnedMessagesWaitForTheComposerAndMerge() {
        returns.returnToComposer(PendingMessage(text: "one"), for: "lead")
        returns.returnToComposer(PendingMessage(text: "two"), for: "lead")

        #expect(returns.takeReturned(for: "lead")?.text == "one\n\ntwo")
        #expect(returns.takeReturned(for: "lead") == nil)
    }

    @Test func returnedMessagesArePerTarget() {
        returns.returnToComposer(PendingMessage(text: "to a"), for: "agent-a")
        returns.returnToComposer(PendingMessage(text: "to b"), for: "agent-b")

        #expect(returns.takeReturned(for: "agent-a")?.text == "to a")
        #expect(returns.returned == ["agent-b": PendingMessage(text: "to b")])
    }

    @Test func restoringIntoAnEmptyComposerKeepsTheMessageExactly() {
        let held = PendingMessage(text: "  keep my spacing\n", attachments: [.pastedText(id: UUID(), index: 1, text: "x")])

        #expect(PendingMessage(text: " \n").appending(held) == held)
    }

    @Test func restoringIntoADraftAppendsAfterABlankLineAndRenumbersPastes() {
        let draftPaste = ChatAttachment.pastedText(id: UUID(), index: 1, text: "draft paste")
        let heldPasteID = UUID()
        let image = ChatAttachment.image(id: UUID(), mediaType: "image/png", fileName: "a.png", data: Data([1]))
        let draft = PendingMessage(text: "new draft\n", attachments: [draftPaste])
        let held = PendingMessage(text: "held message", attachments: [image, .pastedText(id: heldPasteID, index: 1, text: "held paste")])

        let merged = draft.appending(held)

        #expect(merged.text == "new draft\n\nheld message")
        #expect(merged.attachments == [draftPaste, image, .pastedText(id: heldPasteID, index: 2, text: "held paste")])
    }
}
