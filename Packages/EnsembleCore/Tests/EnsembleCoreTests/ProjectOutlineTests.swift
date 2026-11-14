import Foundation
import Testing
@testable import EnsembleCore

struct ProjectOutlineTests {
    func item(_ kind: ChatRequestKind) -> ChatRequest {
        ChatRequest(projectId: 1, kind: kind, title: "Item", createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func theChangesBadgeCountsPinReviews() {
        let badge = ProjectOutline.changesBadge(waiting: [item(.pinReview), item(.pinReview), item(.question)])
        #expect(badge == ProjectOutline.Badge(count: 2, tone: .warning))
        #expect(ProjectOutline.changesBadge(waiting: [item(.question)]) == nil)
    }

    @Test func countBadgesHideAtZero() {
        #expect(ProjectOutline.countBadge(0) == nil)
        #expect(ProjectOutline.countBadge(3) == ProjectOutline.Badge(count: 3, tone: .quiet))
    }

    @Test func theStatusSummaryListsRunsAndWhatNeedsYou() {
        #expect(ProjectOutline.statusSummary(activeRuns: 2, needsYou: 3, failing: 0) == .init(text: "2 runs · 3 need you", tone: .warning))
        #expect(ProjectOutline.statusSummary(activeRuns: 1, needsYou: 1, failing: 0) == .init(text: "1 run · 1 needs you", tone: .warning))
    }

    @Test func theStatusSummaryFlagsFailuresAndIdleProjects() {
        #expect(ProjectOutline.statusSummary(activeRuns: 0, needsYou: 0, failing: 1) == .init(text: "1 failing", tone: .danger))
        #expect(ProjectOutline.statusSummary(activeRuns: 0, needsYou: 0, failing: 0) == .init(text: "idle", tone: .quiet))
    }

    @Test func pathsUnderHomeAreAbbreviated() {
        #expect(ProjectOutline.abbreviatedPath("/Users/me/Code/shopfront", home: "/Users/me") == "~/Code/shopfront")
        #expect(ProjectOutline.abbreviatedPath("/Users/me", home: "/Users/me/") == "~")
        #expect(ProjectOutline.abbreviatedPath("/Users/meg/Code", home: "/Users/me") == "/Users/meg/Code")
        #expect(ProjectOutline.abbreviatedPath("/opt/repo", home: "/Users/me") == "/opt/repo")
    }

    @Test func theBranchLineCountsWorktrees() {
        #expect(ProjectOutline.branchLine(branch: "main", worktrees: 4) == "main · 4 worktrees")
        #expect(ProjectOutline.branchLine(branch: nil, worktrees: 1) == "no branch · 1 worktree")
        #expect(ProjectOutline.pinsLabel(1) == "1 pin")
        #expect(ProjectOutline.pinsLabel(6) == "6 pins")
    }

    @Test func chatAndChangesStartExpanded() {
        #expect(ProjectOutline.decodeExpanded(nil) == ["lead", "changes"])
    }

    @Test func togglingASectionRoundTripsThroughStorage() {
        let collapsed = ProjectOutline.toggling("changes", in: nil)
        #expect(ProjectOutline.decodeExpanded(collapsed) == ["lead"])
        let expanded = ProjectOutline.toggling("agents", in: collapsed)
        #expect(ProjectOutline.decodeExpanded(expanded) == ["lead", "agents"])
        #expect(ProjectOutline.decodeExpanded(ProjectOutline.toggling("lead", in: ProjectOutline.toggling("changes", in: "lead,changes"))).isEmpty)
    }
}
