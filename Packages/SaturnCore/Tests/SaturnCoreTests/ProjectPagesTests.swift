import Foundation
import Testing
@testable import SaturnCore

@Suite struct ProjectPagesTests {
    enum Kind: Codable, Hashable, Sendable {
        case chat(Int)
        case tool(String, project: Int?)
        case project(Int, section: ProjectPageSection)

        var projectPage: Int? {
            if case .project(let id, _) = self { return id }
            return nil
        }

        var migrated: Kind {
            guard case .tool(let tool, let project?) = self, let section = ProjectPageSection(legacyTool: tool) else { return self }
            return .project(project, section: section)
        }
    }

    @Test(arguments: [
        ("changes", ProjectPageSection.changes),
        ("agents", .agents),
        ("workflows", .workflows),
        ("code", .source),
        ("settings", .settings),
    ])
    func mapsLegacyToolsToSections(tool: String, section: ProjectPageSection) {
        #expect(ProjectPageSection(legacyTool: tool) == section)
    }

    @Test func usageStaysATool() {
        #expect(ProjectPageSection(legacyTool: "usage") == nil)
    }

    @Test func migrationMergesToolPagesIntoOneProjectPage() {
        var list = PageList<Kind>()
        list.open(.tool("agents", project: 1), unique: false)
        list.open(.chat(7), unique: false)
        list.open(.tool("code", project: 1), unique: false)
        list.open(.tool("changes", project: 2), unique: false)
        list.open(.tool("usage", project: nil), unique: false)
        list.select(index: 2)
        let firstID = list.pages[0].id
        list.migrate(\.migrated, uniqueBy: \.projectPage)
        #expect(list.pages.map(\.kind) == [.project(1, section: .source), .chat(7), .project(2, section: .changes), .tool("usage", project: nil)])
        #expect(list.activeID == firstID)
    }

    @Test func migrationKeepsFirstSectionWhenDuplicateIsInactive() {
        var list = PageList<Kind>()
        list.open(.tool("workflows", project: 1), unique: false)
        list.open(.tool("settings", project: 1), unique: false)
        list.select(index: 0)
        list.migrate(\.migrated, uniqueBy: \.projectPage)
        #expect(list.pages.map(\.kind) == [.project(1, section: .workflows)])
    }

    @Test func openOrUpdateKeepsOnePagePerProject() {
        var list = PageList<Kind>()
        let first = list.openOrUpdate(.project(1, section: .overview)) { $0.projectPage == 1 }
        list.open(.chat(3))
        let again = list.openOrUpdate(.project(1, section: .chats)) { $0.projectPage == 1 }
        list.openOrUpdate(.project(2, section: .overview)) { $0.projectPage == 2 }
        #expect(again == first)
        #expect(list.pages.map(\.kind) == [.project(1, section: .chats), .chat(3), .project(2, section: .overview)])
        list.focus(first)
        #expect(list.active?.kind == .project(1, section: .chats))
    }

    @Test(arguments: [
        ("monorepo", "mono", true),
        ("monorepo", "REPO", true),
        ("monorepo", "", true),
        ("monorepo", "  ", true),
        ("monorepo", "saturn", false),
        ("Saturn App", "app", true),
    ])
    func matchesProjectsByName(name: String, query: String, expected: Bool) {
        #expect(ProjectSearch.matches(name, query: query) == expected)
    }

    @Test func binsSpendByWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9)))
        let wednesday = monday.addingTimeInterval(2 * 86_400)
        let lastWeek = monday.addingTimeInterval(-86_400)
        let days = WeekSpend.byDay([(monday, 1.5), (wednesday, 2), (wednesday, 0.5), (lastWeek, 9)], weekOf: wednesday, calendar: calendar)
        #expect(days == [1.5, 0, 2.5, 0, 0, 0, 0])
    }

    @Test func readsOriginFromGitConfig() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = https://github.com/other/repo.git
        [remote "origin"]
        \turl = git@github.com:acme/monorepo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        let origin = GitRemote.origin(inConfig: config)
        #expect(origin == "git@github.com:acme/monorepo.git")
        #expect(origin.map(GitRemote.displayName) == "github.com/acme/monorepo")
        #expect(GitRemote.displayName("https://github.com/acme/monorepo.git") == "github.com/acme/monorepo")
        #expect(GitRemote.origin(inConfig: "[core]\n\tbare = false") == nil)
    }
}
