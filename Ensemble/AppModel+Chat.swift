import EnsembleCore
import Foundation

enum ChatTarget: Hashable {
    case lead(String)
    case agent(Int64)
}

enum PendingSendTarget: Hashable {
    case session(Int64)
    case direct(Int64)
    case lead(project: Int64, request: Int64?)
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
    func sendDirectMessage(_ text: String, attachments: [ChatAttachment] = [], to session: AgentSession) -> Bool {
        do {
            try directChat.send(text, attachments: attachments, to: session)
            return true
        } catch {
            alert = AppAlert(title: "Couldn’t send the message to \(displayName(of: session.agent))", message: error.localizedDescription)
            return false
        }
    }

    static let sendHoldSecondsKey = "chat.sendHoldSeconds"
    static let defaultSendHoldSeconds = 3

    var sendHoldSeconds: Int {
        max(UserDefaults.standard.object(forKey: Self.sendHoldSecondsKey) as? Int ?? Self.defaultSendHoldSeconds, 0)
    }

    func holdSend(_ message: PendingMessage, to target: PendingSendTarget, deliver: @escaping @MainActor (PendingMessage) -> Void) {
        pendingSends.schedule(message, for: target, delay: TimeInterval(sendHoldSeconds), deliver: deliver)
    }

    func holdSessionMessage(_ text: String, to session: AgentSession) {
        holdSend(PendingMessage(text: text), to: .session(session.id)) { session.send($0.text) }
    }

    func holdDirectMessage(_ message: PendingMessage, to session: AgentSession) {
        let target = PendingSendTarget.direct(session.id)
        holdSend(message, to: target) { [weak self] held in
            guard let self, !sendDirectMessage(held.text, attachments: held.attachments, to: session) else { return }
            pendingSends.returnToComposer(held, for: target)
        }
    }

    private func defaultLeadRole(in project: Project) -> RoleDefinition? {
        let leads = leadRoles(in: project)
        let current = selectedRequest(in: project).flatMap(leadSession(for:))?.agent.role
        return leads.first { $0.id == current } ?? leads.first
    }
}
