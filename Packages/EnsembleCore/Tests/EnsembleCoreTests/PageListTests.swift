import Foundation
import Testing
@testable import EnsembleCore

@Suite struct PageListTests {
    enum Kind: Codable, Hashable, Sendable {
        case chat(Int?)
        case terminal(String)
        case tool(String)

        var isChat: Bool {
            if case .chat = self { return true }
            return false
        }
    }

    private func list(_ kinds: [Kind]) -> PageList<Kind> {
        var list = PageList<Kind>()
        for kind in kinds { list.open(kind, unique: false) }
        return list
    }

    @Test func opensAndFocusesNewPage() {
        var pages = PageList<Kind>()
        let first = pages.open(.chat(1))
        let second = pages.open(.terminal("/repo"))
        #expect(pages.pages.map(\.id) == [first, second])
        #expect(pages.activeID == second)
        pages.focus(first)
        #expect(pages.active?.kind == .chat(1))
    }

    @Test func focusIgnoresUnknownPages() {
        var pages = list([.chat(1)])
        let active = pages.activeID
        pages.focus(UUID())
        #expect(pages.activeID == active)
    }

    @Test func dedupesEqualPages() {
        var pages = list([.tool("changes"), .chat(1)])
        let again = pages.open(.tool("changes"))
        #expect(pages.pages.count == 2)
        #expect(again == pages.pages[0].id)
        #expect(pages.activeID == again)
    }

    @Test func dedupesByCustomKey() {
        var pages = list([.terminal("/a")])
        pages.open(.terminal("/b"), sameAs: { if case .terminal = $0 { true } else { false } })
        #expect(pages.pages.map(\.kind) == [.terminal("/a")])
    }

    @Test func opensDuplicatesWhenNotUnique() {
        var pages = list([.terminal("/a")])
        pages.open(.terminal("/a"), unique: false)
        #expect(pages.pages.count == 2)
    }

    @Test func showFocusesExistingPage() {
        var pages = list([.chat(1), .chat(2), .terminal("/a")])
        pages.show(.chat(1), replacingActiveWhen: \.isChat)
        #expect(pages.pages.count == 3)
        #expect(pages.active?.kind == .chat(1))
    }

    @Test func showReplacesActiveChat() {
        var pages = list([.terminal("/a"), .chat(1)])
        let id = pages.activeID
        pages.show(.chat(2), replacingActiveWhen: \.isChat)
        #expect(pages.pages.map(\.kind) == [.terminal("/a"), .chat(2)])
        #expect(pages.activeID == id)
    }

    @Test func showOpensNewPageWhenActiveIsNotChat() {
        var pages = list([.chat(1), .terminal("/a")])
        pages.show(.chat(2), replacingActiveWhen: \.isChat)
        #expect(pages.pages.map(\.kind) == [.chat(1), .terminal("/a"), .chat(2)])
        #expect(pages.active?.kind == .chat(2))
    }

    @Test func closingActiveFocusesRightNeighbour() {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        pages.select(index: 1)
        pages.close(pages.pages[1].id)
        #expect(pages.active?.kind == .chat(3))
    }

    @Test func closingLastActiveFocusesNewLast() {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        pages.close(pages.pages[2].id)
        #expect(pages.active?.kind == .chat(2))
    }

    @Test func closingInactiveKeepsActive() {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        pages.close(pages.pages[0].id)
        #expect(pages.active?.kind == .chat(3))
    }

    @Test func closingEveryPageLeavesNoActive() {
        var pages = list([.chat(1)])
        pages.close(pages.pages[0].id)
        #expect(pages.isEmpty)
        #expect(pages.activeID == nil)
    }

    @Test func closeOthersKeepsOnePage() {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        let middle = pages.pages[1].id
        pages.closeOthers(middle)
        #expect(pages.pages.map(\.id) == [middle])
        #expect(pages.activeID == middle)
    }

    @Test(arguments: [
        (IndexSet(integer: 0), 3, [2, 3, 1]),
        (IndexSet(integer: 2), 0, [3, 1, 2]),
        (IndexSet(integer: 0), 2, [2, 1, 3]),
        (IndexSet(integer: 1), 1, [1, 2, 3]),
        (IndexSet([0, 1]), 3, [3, 1, 2]),
    ])
    func reorders(source: IndexSet, destination: Int, expected: [Int]) {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        let active = pages.activeID
        pages.move(fromOffsets: source, toOffset: destination)
        #expect(pages.pages.map(\.kind) == expected.map { .chat($0) })
        #expect(pages.activeID == active)
    }

    @Test func selectsNextAndPreviousWithWrapping() {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        pages.selectNext()
        #expect(pages.active?.kind == .chat(1))
        pages.selectPrevious()
        #expect(pages.active?.kind == .chat(3))
        pages.selectPrevious()
        #expect(pages.active?.kind == .chat(2))
    }

    @Test func selectsByIndex() {
        var pages = list([.chat(1), .chat(2), .chat(3)])
        pages.select(index: 0)
        #expect(pages.active?.kind == .chat(1))
        pages.select(index: 9)
        #expect(pages.active?.kind == .chat(1))
    }

    @Test func replaceMergesIntoExistingPage() {
        var pages = list([.tool("agents"), .chat(1)])
        pages.replace(pages.pages[1].id, with: .tool("agents"))
        #expect(pages.pages.map(\.kind) == [.tool("agents")])
        #expect(pages.active?.kind == .tool("agents"))
    }

    @Test func roundTripsThroughJSON() throws {
        var pages = list([.chat(1), .terminal("/repo"), .chat(nil)])
        pages.select(index: 1)
        let data = try JSONEncoder().encode(pages)
        let decoded = try JSONDecoder().decode(PageList<Kind>.self, from: data)
        #expect(decoded == pages)
        #expect(decoded.active?.kind == .terminal("/repo"))
    }

    @Test func dropsStalePagesAndRefocuses() {
        var pages = list([.chat(1), .chat(2), .terminal("/a")])
        pages.select(index: 1)
        pages.retain { $0.kind != .chat(2) }
        #expect(pages.pages.map(\.kind) == [.chat(1), .terminal("/a")])
        #expect(pages.active?.kind == .terminal("/a"))
        pages.retain { _ in false }
        #expect(pages.activeID == nil)
    }

    @Test func restoredListDropsUnknownActive() {
        let page = Page<Kind>(kind: .chat(1))
        let pages = PageList(pages: [page], activeID: UUID())
        #expect(pages.activeID == page.id)
    }
}
