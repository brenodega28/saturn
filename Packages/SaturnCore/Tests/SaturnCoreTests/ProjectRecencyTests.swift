import Foundation
import Testing
@testable import SaturnCore

struct ProjectRecencyTests {
    func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func project(_ name: String, opened: TimeInterval) -> Project {
        Project(name: name, path: "/tmp/\(name)", isOpen: true, createdAt: at(0), lastOpenedAt: at(opened))
    }

    func chat(_ id: Int64, created: TimeInterval, updated: TimeInterval, closed: Bool = false) -> Chat {
        Chat(id: id, projectId: 1, title: "c\(id)", body: "", source: .chat, status: .running, closedAt: closed ? at(updated) : nil, createdAt: at(created), updatedAt: at(updated))
    }

    @Test func lastUsedIsTheLatestOfOpeningAndAnyChatActivity() {
        let shop = project("shop", opened: 100)
        #expect(ProjectRecency.lastUsed(shop, chats: [], activity: [:]) == at(100))
        #expect(ProjectRecency.lastUsed(shop, chats: [chat(1, created: 10, updated: 50)], activity: [:]) == at(100))
        #expect(ProjectRecency.lastUsed(shop, chats: [chat(1, created: 10, updated: 50), chat(2, created: 20, updated: 300, closed: true)], activity: [:]) == at(300))
        #expect(ProjectRecency.lastUsed(shop, chats: [chat(1, created: 10, updated: 50)], activity: [1: at(500)]) == at(500))
        #expect(ProjectRecency.lastUsed(shop, chats: [chat(1, created: 700, updated: 50)], activity: [1: at(60)]) == at(700))
    }

    @Test func sortsNewestFirstAndBreaksTiesByName() {
        let projects = [project("zeta", opened: 100), project("Alpha", opened: 100), project("mid", opened: 200), project("beta", opened: 100), project("old", opened: 1)]
        let sorted = ProjectRecency.sorted(projects, name: \.name, lastUsed: \.lastOpenedAt)
        #expect(sorted.map(\.name) == ["mid", "Alpha", "beta", "zeta", "old"])
    }

    @Test func identicalNameAndDateKeepInputOrder() {
        let items = [(machine: "a", name: "shop"), (machine: "b", name: "shop"), (machine: "c", name: "shop")]
        let sorted = ProjectRecency.sorted(items, name: \.name, lastUsed: { _ in at(5) })
        #expect(sorted.map(\.machine) == ["a", "b", "c"])
    }
}
