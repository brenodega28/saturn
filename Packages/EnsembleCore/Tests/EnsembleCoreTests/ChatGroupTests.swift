import Foundation
import Testing
@testable import EnsembleCore

struct ChatGroupTests {
    struct Item: Equatable {
        let name: String
        let stage: ChatStage
        let minutesAgo: Double
        var project = "a"
    }

    let now = Date(timeIntervalSince1970: 1_000_000)

    func grouped(_ items: [Item]) -> [ChatGroup: [String]] {
        ChatGroup.grouped(items, stage: \.stage) { now.addingTimeInterval(-$0.minutesAgo * 60) }.mapValues { $0.map(\.name) }
    }

    @Test func stagesMapToGroups() {
        #expect(ChatGroup.of(.needsYou) == .needsYou)
        #expect(ChatGroup.of(.stuck) == .needsYou)
        #expect(ChatGroup.of(.inReview) == .inProgress)
        #expect(ChatGroup.of(.building) == .inProgress)
        #expect(ChatGroup.of(.idle) == .notStarted)
        #expect(ChatGroup.of(.finished) == .finished)
        #expect(ChatGroup.of(.done) == nil)
        #expect(ChatGroup.of(.dropped) == nil)
    }

    @Test func groupsSortByStageThenNewestFirst() {
        let groups = grouped([
            Item(name: "stuck-new", stage: .stuck, minutesAgo: 1),
            Item(name: "need-old", stage: .needsYou, minutesAgo: 50),
            Item(name: "need-new", stage: .needsYou, minutesAgo: 5),
            Item(name: "build", stage: .building, minutesAgo: 1),
            Item(name: "review", stage: .inReview, minutesAgo: 90),
            Item(name: "idle-old", stage: .idle, minutesAgo: 30),
            Item(name: "idle-new", stage: .idle, minutesAgo: 2),
            Item(name: "fin", stage: .finished, minutesAgo: 3),
            Item(name: "done", stage: .done, minutesAgo: 1),
            Item(name: "dropped", stage: .dropped, minutesAgo: 1),
        ])
        #expect(groups[.needsYou] == ["need-new", "need-old", "stuck-new"])
        #expect(groups[.inProgress] == ["review", "build"])
        #expect(groups[.notStarted] == ["idle-new", "idle-old"])
        #expect(groups[.finished] == ["fin"])
        #expect(groups.values.flatMap(\.self).count == 8)
    }

    @Test func emptyGroupsAreAbsent() {
        let groups = grouped([Item(name: "x", stage: .building, minutesAgo: 1)])
        #expect(groups.keys.sorted { $0.rawValue < $1.rawValue } == [.inProgress])
        #expect(grouped([]).isEmpty)
    }

    @Test func filterKeyFallsBackToAllWhenProjectIsGone() {
        let daemon = UUID()
        let key = ProjectFilterKey.make(daemon: daemon, projectID: 4)
        let other = ProjectFilterKey.make(daemon: UUID(), projectID: 4)
        #expect(key != other)
        #expect(ProjectFilterKey.resolve(key, among: [other, key]) == key)
        #expect(ProjectFilterKey.resolve(key, among: [other]) == ProjectFilterKey.all)
        #expect(ProjectFilterKey.resolve(ProjectFilterKey.all, among: [key]) == ProjectFilterKey.all)
    }

    @Test func filterMatchesOnlyTheActiveProject() {
        let items = [Item(name: "1", stage: .idle, minutesAgo: 1, project: "a"), Item(name: "2", stage: .idle, minutesAgo: 1, project: "b")]
        #expect(ProjectFilterKey.filter(items, by: ProjectFilterKey.all, key: \.project).map(\.name) == ["1", "2"])
        #expect(ProjectFilterKey.filter(items, by: "b", key: \.project).map(\.name) == ["2"])
    }
}
