import Foundation
import Testing
@testable import EnsembleCore

@Suite struct ChatLinkTests {
    @Test func buildsRequestLink() {
        #expect(ChatLink(requestID: 42).url.absoluteString == "ensemble://chat/42")
    }

    @Test func buildsMessageLink() {
        #expect(ChatLink(requestID: 42, messageID: 7).url.absoluteString == "ensemble://chat/42?message=7")
    }

    @Test(arguments: [ChatLink(requestID: 1), ChatLink(requestID: 42, messageID: 7), ChatLink(requestID: Int64.max, messageID: Int64.max)])
    func roundTrips(link: ChatLink) {
        #expect(ChatLink(url: link.url) == link)
        #expect(ChatLink(string: link.url.absoluteString) == link)
    }

    @Test func parsesMessageAnchor() {
        let link = ChatLink(string: "ensemble://chat/42?message=7")
        #expect(link?.requestID == 42)
        #expect(link?.messageID == 7)
    }

    @Test func trimsWhitespace() {
        #expect(ChatLink(string: "  ensemble://chat/42?message=7\n") == ChatLink(requestID: 42, messageID: 7))
    }

    @Test func acceptsUppercaseSchemeAndHost() {
        #expect(ChatLink(string: "ENSEMBLE://Chat/42") == ChatLink(requestID: 42))
    }

    @Test func acceptsTrailingSlash() {
        #expect(ChatLink(string: "ensemble://chat/42/") == ChatLink(requestID: 42))
    }

    @Test(arguments: [
        "",
        "ensemble://chat",
        "ensemble://chat/",
        "ensemble://run/42",
        "ensemble://agent/42",
        "https://chat/42",
        "ensembles://chat/42",
        "ensemble://chat/abc",
        "ensemble://chat/0",
        "ensemble://chat/-3",
        "ensemble://chat/+3",
        "ensemble://chat/4.2",
        "ensemble://chat/99999999999999999999",
        "ensemble://chat/42/extra",
        "ensemble://chat/42/message/7",
        "ensemble://chat/42?message=abc",
        "ensemble://chat/42?message=0",
        "ensemble://chat/42?message=-1",
        "ensemble://chat/42?message=",
        "ensemble://chat/42?message",
        "ensemble://chat/42?message=1&message=2",
        "not a link",
    ])
    func rejectsBadInput(string: String) {
        #expect(ChatLink(string: string) == nil)
    }

    @Test func ignoresUnrelatedQueryItems() {
        #expect(ChatLink(string: "ensemble://chat/42?from=slack&message=7") == ChatLink(requestID: 42, messageID: 7))
    }
}
