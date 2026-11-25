import Foundation
import Testing
@testable import SaturnCore

@Suite struct ChatLinkTests {
    @Test func buildsRequestLink() {
        #expect(ChatLink(requestID: 42).url.absoluteString == "saturn://chat/42")
    }

    @Test func buildsMessageLink() {
        #expect(ChatLink(requestID: 42, messageID: 7).url.absoluteString == "saturn://chat/42?message=7")
    }

    @Test(arguments: [ChatLink(requestID: 1), ChatLink(requestID: 42, messageID: 7), ChatLink(requestID: Int64.max, messageID: Int64.max)])
    func roundTrips(link: ChatLink) {
        #expect(ChatLink(url: link.url) == link)
        #expect(ChatLink(string: link.url.absoluteString) == link)
    }

    @Test func parsesMessageAnchor() {
        let link = ChatLink(string: "saturn://chat/42?message=7")
        #expect(link?.requestID == 42)
        #expect(link?.messageID == 7)
    }

    @Test func acceptsTheLegacySchemeAsAnAlias() {
        let link = ChatLink(string: "\(LegacyMigration.Legacy.urlScheme)://chat/42?message=7")
        #expect(link == ChatLink(requestID: 42, messageID: 7))
        #expect(link?.url.scheme == ChatLink.scheme)
    }

    @Test func trimsWhitespace() {
        #expect(ChatLink(string: "  saturn://chat/42?message=7\n") == ChatLink(requestID: 42, messageID: 7))
    }

    @Test func acceptsUppercaseSchemeAndHost() {
        #expect(ChatLink(string: "SATURN://Chat/42") == ChatLink(requestID: 42))
    }

    @Test func acceptsTrailingSlash() {
        #expect(ChatLink(string: "saturn://chat/42/") == ChatLink(requestID: 42))
    }

    @Test(arguments: [
        "",
        "saturn://chat",
        "saturn://chat/",
        "saturn://run/42",
        "saturn://agent/42",
        "https://chat/42",
        "saturns://chat/42",
        "saturn://chat/abc",
        "saturn://chat/0",
        "saturn://chat/-3",
        "saturn://chat/+3",
        "saturn://chat/4.2",
        "saturn://chat/99999999999999999999",
        "saturn://chat/42/extra",
        "saturn://chat/42/message/7",
        "saturn://chat/42?message=abc",
        "saturn://chat/42?message=0",
        "saturn://chat/42?message=-1",
        "saturn://chat/42?message=",
        "saturn://chat/42?message",
        "saturn://chat/42?message=1&message=2",
        "not a link",
    ])
    func rejectsBadInput(string: String) {
        #expect(ChatLink(string: string) == nil)
    }

    @Test func ignoresUnrelatedQueryItems() {
        #expect(ChatLink(string: "saturn://chat/42?from=slack&message=7") == ChatLink(requestID: 42, messageID: 7))
    }

    private static let daemon = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test func buildsDaemonLink() {
        #expect(ChatLink(requestID: 42, messageID: 7, daemon: Self.daemon).url.absoluteString
            == "saturn://chat/42?daemon=6f9619ff-8b86-d011-b42d-00c04fc964ff&message=7")
    }

    @Test(arguments: [ChatLink(requestID: 42, daemon: daemon), ChatLink(requestID: 42, messageID: 7, daemon: daemon)])
    func roundTripsWithDaemon(link: ChatLink) {
        #expect(ChatLink(url: link.url) == link)
        #expect(ChatLink(string: link.url.absoluteString) == link)
    }

    @Test func parsesDaemonAndMessage() {
        let link = ChatLink(string: "saturn://chat/42?message=7&daemon=6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(link == ChatLink(requestID: 42, messageID: 7, daemon: Self.daemon))
    }

    @Test func parsesLinkWithoutDaemon() {
        let link = ChatLink(string: "saturn://chat/42?message=7")
        #expect(link == ChatLink(requestID: 42, messageID: 7))
        #expect(link?.daemon == nil)
    }

    @Test(arguments: [
        "saturn://chat/42?daemon=nope&message=7",
        "saturn://chat/42?daemon=&message=7",
        "saturn://chat/42?daemon&message=7",
    ])
    func ignoresInvalidDaemon(string: String) {
        #expect(ChatLink(string: string) == ChatLink(requestID: 42, messageID: 7))
    }

    @Test func ignoresRepeatedDaemon() {
        let other = UUID().uuidString
        #expect(ChatLink(string: "saturn://chat/42?daemon=\(Self.daemon.uuidString)&daemon=\(other)")?.daemon == nil)
    }
}
