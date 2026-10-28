import Foundation
import Testing
@testable import EnsembleCore

@MainActor
final class ManualPendingSendClock: PendingSendClock {
    var now = Date(timeIntervalSince1970: 1_000)
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(until deadline: Date) async throws {
        await withCheckedContinuation { continuation in
            sleepers.append((deadline, continuation))
        }
    }

    func advance(by seconds: TimeInterval) async {
        await settle()
        now = now.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        due.forEach { $0.continuation.resume() }
        await settle()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
struct PendingSendTests {
    let clock = ManualPendingSendClock()
    let sends: PendingSends<String>
    let delivered = Delivered()

    init() {
        sends = PendingSends(clock: clock)
    }

    @MainActor
    final class Delivered {
        var messages: [String] = []
    }

    @discardableResult
    func schedule(_ text: String, to target: String = "agent-a", delay: TimeInterval = 3) -> PendingSends<String>.Hold? {
        let delivered = delivered
        return sends.schedule(PendingMessage(text: text), for: target, delay: delay) { delivered.messages.append($0.text) }
    }

    @Test func aScheduledSendIsHeldUntilItsDeadline() async {
        let hold = schedule("hello")

        #expect(hold?.deadline == clock.now.addingTimeInterval(3))
        #expect(sends.holds(for: "agent-a").map(\.message.text) == ["hello"])
        await clock.advance(by: 2.9)
        #expect(delivered.messages.isEmpty)
        #expect(sends.holds.count == 1)
    }

    @Test func aHeldSendIsDeliveredOnceAfterItsDeadline() async {
        schedule("hello")

        await clock.advance(by: 3)
        #expect(delivered.messages == ["hello"])
        #expect(sends.holds.isEmpty)
        await clock.advance(by: 10)
        #expect(delivered.messages == ["hello"])
    }

    @Test func undoBeforeTheDeadlineCancelsAndReturnsTheMessage() async {
        let attachment = ChatAttachment.pastedText(id: UUID(), index: 1, text: "long paste")
        let hold = sends.schedule(PendingMessage(text: "oops", attachments: [attachment]), for: "agent-a", delay: 3) { _ in
            Issue.record("An undone send must not be delivered")
        }

        await clock.advance(by: 1)
        let restored = sends.undo(hold!.id)
        #expect(restored == PendingMessage(text: "oops", attachments: [attachment]))
        #expect(sends.holds.isEmpty)
        await clock.advance(by: 5)
        #expect(sends.undo(hold!.id) == nil)
    }

    @Test func zeroDelayDeliversImmediatelyWithoutAHold() {
        let hold = schedule("now", delay: 0)

        #expect(hold == nil)
        #expect(delivered.messages == ["now"])
        #expect(sends.holds.isEmpty)
    }

    @Test func aSecondSendHoldsIndependentlyAndDeliversInOrder() async {
        schedule("first")
        await clock.advance(by: 1)
        let second = schedule("second")

        #expect(sends.holds(for: "agent-a").map(\.message.text) == ["first", "second"])
        await clock.advance(by: 2)
        #expect(delivered.messages == ["first"])
        #expect(sends.holds.map(\.id) == [second!.id])
        await clock.advance(by: 1)
        #expect(delivered.messages == ["first", "second"])
    }

    @Test func undoingTheFirstOfTwoKeepsTheSecondOnItsOwnTimer() async {
        let first = schedule("first")
        await clock.advance(by: 1)
        schedule("second")

        #expect(sends.undo(first!.id)?.text == "first")
        await clock.advance(by: 2)
        #expect(delivered.messages.isEmpty)
        await clock.advance(by: 1)
        #expect(delivered.messages == ["second"])
    }

    @Test func aZeroDelaySendWaitsBehindAPendingOneToKeepOrder() async {
        schedule("first")
        let second = schedule("second", delay: 0)

        #expect(second != nil)
        #expect(delivered.messages.isEmpty)
        await clock.advance(by: 3)
        #expect(delivered.messages == ["first", "second"])
    }

    @Test func holdsArePerTarget() async {
        schedule("to a", to: "agent-a")
        schedule("to b", to: "agent-b")

        #expect(sends.undoLatest(for: "agent-a")?.text == "to a")
        #expect(sends.holds(for: "agent-a").isEmpty)
        await clock.advance(by: 3)
        #expect(delivered.messages == ["to b"])
    }

    @Test func undoLatestTakesTheMostRecentHold() {
        schedule("first")
        schedule("second")

        #expect(sends.undoLatest(for: "agent-a")?.text == "second")
        #expect(sends.holds.map(\.message.text) == ["first"])
        #expect(sends.undoLatest(for: "nobody") == nil)
    }

    @Test func returnedMessagesWaitForTheComposerAndMerge() {
        sends.returnToComposer(PendingMessage(text: "one"), for: "lead")
        sends.returnToComposer(PendingMessage(text: "two"), for: "lead")

        #expect(sends.takeReturned(for: "lead")?.text == "one\n\ntwo")
        #expect(sends.takeReturned(for: "lead") == nil)
    }

    @Test func cancelStopsTheHoldAndReturnsItsMessageToTheComposer() async {
        let first = schedule("first")
        schedule("second")

        #expect(sends.cancel(first!.id))
        #expect(sends.holds.map(\.message.text) == ["second"])
        #expect(sends.returned["agent-a"]?.text == "first")
        #expect(!sends.cancel(first!.id))
        await clock.advance(by: 3)
        #expect(delivered.messages == ["second"])
        #expect(sends.takeReturned(for: "agent-a")?.text == "first")
    }

    @Test func cancellingTwoHoldsMergesThemForTheComposer() {
        let first = schedule("first")
        let second = schedule("second")

        sends.cancel(second!.id)
        sends.cancel(first!.id)

        #expect(sends.holds.isEmpty)
        #expect(sends.takeReturned(for: "agent-a")?.text == "second\n\nfirst")
    }

    @Test func cancelLatestReturnsTheMostRecentHoldForThatTargetOnly() {
        schedule("to a", to: "agent-a")
        schedule("to b", to: "agent-b")
        schedule("to a again", to: "agent-a")

        #expect(sends.cancelLatest(for: "agent-a"))
        #expect(sends.holds.map(\.message.text) == ["to a", "to b"])
        #expect(sends.returned == ["agent-a": PendingMessage(text: "to a again")])
        #expect(!sends.cancelLatest(for: "nobody"))
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
