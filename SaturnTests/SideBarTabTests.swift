import Foundation
import SaturnCore
import Testing
@testable import Saturn

@MainActor
struct SideBarTabTests {
    private func savedJSON(_ tab: String) throws -> Data {
        let saved = MainPages.Saved(list: PageList(), isSideBarOpen: true, sideBarTab: .task)
        let json = try #require(String(data: JSONEncoder().encode(saved), encoding: .utf8))
        return Data(json.replacingOccurrences(of: "\"sideBarTab\":\"task\"", with: "\"sideBarTab\":\"\(tab)\"").utf8)
    }

    @Test func legacySummaryOpensOnTask() throws {
        let saved = try JSONDecoder().decode(MainPages.Saved.self, from: savedJSON("summary"))
        #expect(saved.sideBarTab == .task)
    }

    @Test func unknownTabOpensOnTask() throws {
        let saved = try JSONDecoder().decode(MainPages.Saved.self, from: savedJSON("somethingNew"))
        #expect(saved.sideBarTab == .task)
    }

    @Test(arguments: SideBarTab.allCases)
    func tabRoundTrips(_ tab: SideBarTab) throws {
        let saved = MainPages.Saved(list: PageList(), isSideBarOpen: false, sideBarTab: tab)
        let decoded = try JSONDecoder().decode(MainPages.Saved.self, from: JSONEncoder().encode(saved))
        #expect(decoded.sideBarTab == tab)
        #expect(decoded.isSideBarOpen == false)
    }

    @Test func tabsAreTaskProjectLog() {
        #expect(SideBarTab.allCases == [.task, .project, .log])
        #expect(SideBarTab.allCases.map(\.title) == ["Task", "Project", "Log"])
    }
}

struct ChatLogFilterTests {
    private func entry(_ kind: ChatLogEntry.Kind) -> ChatLogEntry {
        ChatLogEntry(id: "\(kind)", date: .now, who: "Someone", tag: "Tag", tone: .idle, text: "Text", kind: kind)
    }

    @Test func allMatchesEveryKind() {
        #expect([.lead, .worker, .tool].map(entry).allSatisfy(ChatLogFilter.all.matches))
    }

    @Test(arguments: [
        (ChatLogFilter.lead, ChatLogEntry.Kind.lead),
        (.workers, .worker),
        (.tools, .tool),
    ])
    func filterMatchesOnlyItsKind(_ filter: ChatLogFilter, _ kind: ChatLogEntry.Kind) {
        for other in [ChatLogEntry.Kind.lead, .worker, .tool] {
            #expect(filter.matches(entry(other)) == (other == kind))
        }
    }

    @Test func filterTitles() {
        #expect(ChatLogFilter.allCases.map(\.title) == ["All", "Lead", "Workers", "Tools"])
    }
}

struct SideBarHelperTests {
    @Test func stageBarMarksCurrentStage() {
        #expect(StageBar.current(.idle, hasRun: false) == 0)
        #expect(StageBar.current(.needsYou, hasRun: false) == 0)
        #expect(StageBar.current(.needsYou, hasRun: true) == 1)
        #expect(StageBar.current(.building, hasRun: true) == 1)
        #expect(StageBar.current(.inReview, hasRun: true) == 2)
        #expect(StageBar.current(.finished, hasRun: true) == 4)
    }

    @Test func statCountsComeFromStages() {
        let counts = ProjectStatCounts(open: [.building, .needsYou, .stuck, .finished, .idle], closed: [.done, .dropped], workersRunning: 2)
        #expect(counts == ProjectStatCounts(active: 4, workersRunning: 2, needsYou: 2, finished: 2))
    }

    @Test func elapsedTimeIsCompact() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ElapsedTime.label(since: start, now: start.addingTimeInterval(5 * 60)) == "5m")
        #expect(ElapsedTime.label(since: start, now: start.addingTimeInterval(2 * 3600 + 14 * 60)) == "2h 14m")
        #expect(ElapsedTime.label(since: start, now: start.addingTimeInterval(26 * 3600)) == "1d 2h")
    }
}
