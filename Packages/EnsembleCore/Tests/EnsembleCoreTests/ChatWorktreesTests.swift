import Foundation
import Testing
@testable import EnsembleCore

struct ChatWorktreesTests {
    func agent(_ id: Int64, taskId: Int64? = nil, runId: Int64? = nil, worktree: String? = "/repo/.crew/a", archived: Bool = false) -> Agent {
        var agent = Agent(id: id, projectId: 1, runId: runId, role: "builder", name: "dev-\(id)", status: .idle, createdAt: .now, updatedAt: .now)
        agent.taskId = taskId
        agent.worktreePath = worktree
        agent.archivedAt = archived ? .now : nil
        return agent
    }

    @Test func onlyThisChatsWorkersWithAWorktreeAreListed() {
        let agents = [
            agent(1, runId: 7),
            agent(2, taskId: 3),
            agent(3, runId: 8),
            agent(4, runId: 7, worktree: nil),
            agent(5, runId: 7, archived: true),
            agent(6, taskId: 4),
        ]

        let listed = ChatWorktrees.agents(agents, inChat: 3, runIDs: [7])

        #expect(listed.map(\.id) == [1, 2])
    }

    @Test func noChatMeansNoWorktrees() {
        #expect(ChatWorktrees.agents([agent(1, runId: 7)], inChat: nil, runIDs: [7]).isEmpty)
    }
}
