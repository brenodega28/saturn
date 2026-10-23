import EnsembleCore
import Foundation

enum ChatTarget: Hashable {
    case lead(String)
    case agent(Int64)
}

extension AppModel {
    func chatTarget(in project: Project) -> ChatTarget? {
        guard let id = project.id else { return nil }
        switch chatTargets[id] {
        case .agent(let agentID) where directChatSessions(in: project).contains(where: { $0.id == agentID }):
            return .agent(agentID)
        case .lead(let roleID) where leadRoles(in: project).contains(where: { $0.id == roleID }):
            return .lead(roleID)
        default:
            return defaultLeadRole(in: project).map { .lead($0.id) }
        }
    }

    func chooseChatTarget(_ target: ChatTarget, in project: Project) {
        guard let id = project.id else { return }
        if case .lead(let roleID) = target, let request = selectedRequest(in: project),
           let lead = leadSession(for: request), lead.agent.role != roleID {
            leadSelections[id] = .newRequest
        }
        chatTargets[id] = target
    }

    func chatLeadRole(in project: Project) -> RoleDefinition? {
        guard case .lead(let roleID) = chatTarget(in: project) else { return nil }
        return leadRoles(in: project).first { $0.id == roleID }
    }

    func directChatSession(in project: Project) -> AgentSession? {
        guard case .agent(let agentID) = chatTarget(in: project) else { return nil }
        return directChatSessions(in: project).first { $0.id == agentID }
    }

    func directChatSessions(in project: Project) -> [AgentSession] {
        agentSessions(in: project).filter { $0.agent.taskId == nil && $0.agent.archivedAt == nil }
    }

    func directChatGroups(in project: Project) -> [AgentGroup] {
        let sessions = directChatSessions(in: project)
        return AgentGroup.make(sessions, runs: runs(for: sessions), describe: runGroupDescription)
    }

    func directMessages(with session: AgentSession) -> [DirectMessage] {
        directChat.messages(with: session.agent)
    }

    @discardableResult
    func sendDirectMessage(_ text: String, to session: AgentSession) -> Bool {
        do {
            try directChat.send(text, to: session)
            return true
        } catch {
            alert = AppAlert(title: "Couldn’t send the message to \(session.agent.name)", message: error.localizedDescription)
            return false
        }
    }

    private func defaultLeadRole(in project: Project) -> RoleDefinition? {
        let leads = leadRoles(in: project)
        let current = selectedRequest(in: project).flatMap(leadSession(for:))?.agent.role
        return leads.first { $0.id == current } ?? leads.first
    }
}
