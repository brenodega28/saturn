import Foundation

extension AgentWorkflowDriver {
    func setChatStatus(_ status: ChatStatusTarget, reason: String?, from agent: Agent) throws -> String {
        guard agent.kind == .lead, let taskId = agent.taskId else {
            throw HandoffError.notAllowed("Only a request’s lead can set its chat status.")
        }
        let database = runtime.database
        if status != .open, try database.runs(taskId: taskId).contains(where: \.isActive) {
            throw HandoffError.notAllowed("A run for this request is still going, so the chat can’t be marked \(status.title). Wait until the run ends, or ask the user to cancel it.")
        }
        let now = Date()
        switch status {
        case .open:
            try database.setClosed(taskId: taskId, reason: nil, at: now)
            closingTasks.remove(taskId)
        case .finished:
            try database.setFinished(taskId: taskId, at: now)
            closingTasks.remove(taskId)
        case .resolved, .closed:
            try database.setClosed(taskId: taskId, reason: status.closeReason, at: now)
            closingTasks.insert(taskId)
        }
        let note = "Lead marked this chat \(status.title)" + (reason.map { " — \($0)" } ?? "")
        try database.insert(LeadMessage(projectId: agent.projectId, taskId: taskId, kind: .note, text: note, createdAt: now))
        switch status {
        case .open:
            return "The chat is Open again."
        case .finished:
            return "The chat is marked Finished. Its agents, worktrees and branches stay so the user can review and continue."
        case .resolved, .closed:
            return "The chat is \(status.title). Its agents, worktrees and branches are deleted after your turn ends, so end your turn now."
        }
    }
}
