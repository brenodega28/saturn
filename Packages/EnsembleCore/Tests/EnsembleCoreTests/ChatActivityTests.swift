import Foundation
import Testing
@testable import EnsembleCore

struct ChatActivityTests {
    func message(_ kind: LeadMessageKind, status: ProposalStatus? = nil) -> LeadMessage {
        LeadMessage(projectId: 1, taskId: 1, kind: kind, text: "", status: status, createdAt: .now)
    }

    @Test func anIdleLeadHasNoActivity() {
        #expect(ChatActivity.lead(needsYou: false, messages: [message(.user), message(.lead)], status: .idle, isQueued: false) == nil)
        #expect(ChatActivity.lead(needsYou: false, messages: [], status: nil, isQueued: false) == nil)
    }

    @Test func aWorkingOrQueuedLeadIsReplying() {
        #expect(ChatActivity.lead(needsYou: false, messages: [], status: .working, isQueued: false) == .replying)
        #expect(ChatActivity.lead(needsYou: false, messages: [], status: .idle, isQueued: true) == .replying)
    }

    @Test func onlyAnOpenProposalMakesAPlanReady() {
        let settled = [message(.proposal, status: .started), message(.proposal, status: .dismissed)]
        #expect(ChatActivity.lead(needsYou: false, messages: settled, status: .idle, isQueued: false) == nil)
        #expect(ChatActivity.lead(needsYou: false, messages: settled + [message(.proposal, status: .open)], status: .working, isQueued: false) == .planReady)
    }

    @Test func aRequestThatNeedsYouOutranksAPlan() {
        let proposal = [message(.proposal, status: .open)]
        #expect(ChatActivity.lead(needsYou: true, messages: proposal, status: .working, isQueued: false) == .needsYou)
        #expect(ChatActivity.lead(needsYou: false, messages: proposal, status: .needsInput, isQueued: false) == .needsYou)
    }

    @Test func aDirectChatIsReplyingWhileItWorksOnAMessage() {
        #expect(ChatActivity.directChat(status: .working, awaitingReply: true, isQueued: false) == .replying)
        #expect(ChatActivity.directChat(status: .idle, awaitingReply: true, isQueued: true) == .replying)
        #expect(ChatActivity.directChat(status: .idle, awaitingReply: false, isQueued: true) == nil)
        #expect(ChatActivity.directChat(status: .idle, awaitingReply: true, isQueued: false) == nil)
        #expect(ChatActivity.directChat(status: .stopped, awaitingReply: false, isQueued: false) == nil)
    }

    @Test func aDirectChatAskingForInputNeedsYou() {
        #expect(ChatActivity.directChat(status: .needsInput, awaitingReply: false, isQueued: false) == .needsYou)
    }

    @Test func activitiesRankByUrgency() {
        #expect([ChatActivity.replying, .needsYou, .planReady].max() == .needsYou)
        #expect([ChatActivity.replying, .planReady].max() == .planReady)
        #expect(ChatActivity.allCases.filter(\.waitsOnYou) == [.planReady, .needsYou])
    }
}
