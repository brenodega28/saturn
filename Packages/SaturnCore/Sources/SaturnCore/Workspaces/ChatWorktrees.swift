import Foundation

public enum ChatWorktrees {
    public static func agents(_ agents: [Agent], inChat chatID: Int64?, runIDs: Set<Int64>) -> [Agent] {
        guard let chatID else { return [] }
        return agents.filter { agent in
            guard agent.archivedAt == nil, agent.worktreeURL != nil else { return false }
            if agent.taskId == chatID { return true }
            return agent.runId.map(runIDs.contains) ?? false
        }
    }
}
