import EnsembleCore
import Foundation

enum ChatTarget: Hashable {
    case lead(String)
    case agent(Int64)
}

struct SidebarChat: Identifiable, Hashable {
    let target: ChatTarget
    let name: String
    let activity: ChatActivity
    var requestID: Int64?

    var id: ChatTarget { target }
}

extension AppModel {
    func sidebarChats(in project: Project) -> [SidebarChat] {
        leadSidebarChats(in: project) + directSidebarChats(in: project)
    }

    func openChat(_ target: ChatTarget, inProjectID id: Int64) {
        if let project = project(withID: id) {
            if let requestID = sidebarChats(in: project).first(where: { $0.target == target })?.requestID {
                leadSelections[id] = .request(requestID)
            }
            chooseChatTarget(target, in: project)
        }
        runDetailIDs[id] = nil
        tabs[id] = .lead
        selection = .project(id)
    }

    func sidebarChatDestination(inProjectID id: Int64) -> SidebarDestination? {
        guard let project = project(withID: id), let target = chatTarget(in: project),
              sidebarChats(in: project).contains(where: { $0.target == target }) else { return nil }
        return .chat(project: id, target: target)
    }

    private func leadSidebarChats(in project: Project) -> [SidebarChat] {
        let roles = leadRoles(in: project)
        guard !roles.isEmpty else { return [] }
        let needsYouTaskIDs = needsYouTaskIDs()
        var chats: [String: SidebarChat] = [:]
        for request in LeadRequest.partition(leadRequests(in: project)).open {
            guard let taskID = request.id, let session = leadSession(for: request),
                  let role = roles.first(where: { $0.id == session.agent.role }) else { continue }
            let activity = ChatActivity.lead(
                needsYou: requestNeedsYou(request, latestRun: latestRun(of: request), needsYouTaskIDs: needsYouTaskIDs),
                messages: (try? database.leadMessages(taskId: taskID)) ?? [],
                status: displayStatus(of: session.agent),
                isQueued: session.isQueued
            )
            guard let activity, chats[role.id].map({ activity > $0.activity }) ?? true else { continue }
            chats[role.id] = SidebarChat(target: .lead(role.id), name: role.name, activity: activity, requestID: taskID)
        }
        return roles.compactMap { chats[$0.id] }
    }

    private func directSidebarChats(in project: Project) -> [SidebarChat] {
        directChatSessions(in: project).compactMap { session in
            let activity = ChatActivity.directChat(
                status: displayStatus(of: session.agent),
                awaitingReply: directMessages(with: session).contains(where: \.awaitingReply),
                isQueued: session.isQueued
            )
            return activity.map { SidebarChat(target: .agent(session.id), name: displayName(of: session.agent, in: project), activity: $0) }
        }
    }


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

    private func defaultLeadRole(in project: Project) -> RoleDefinition? {
        let leads = leadRoles(in: project)
        let current = selectedRequest(in: project).flatMap(leadSession(for:))?.agent.role
        return leads.first { $0.id == current } ?? leads.first
    }
}
