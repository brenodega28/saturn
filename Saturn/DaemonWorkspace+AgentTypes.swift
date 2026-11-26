import SaturnCore

extension DaemonWorkspace {
    func agentTypes(in project: Project) -> [AgentType] {
        agentTypes(of: liveAgents(in: project), in: project)
    }

    func agentTypes(of sessions: [LiveAgentSession], in project: Project, includesArchived: Bool = false) -> [AgentType] {
        let config = config(for: project)
        return AgentType.grouped(sessions, includesArchived: includesArchived, role: config.role) { displayStatus(of: $0.agent) }
    }

    func agentTypeFilter(in project: Project) -> String? {
        project.id.flatMap { agentTypeFilters[$0] }
    }

    func setAgentTypeFilter(_ roleID: String?, in project: Project) {
        guard let id = project.id else { return }
        agentTypeFilters[id] = roleID
    }

    func openAgentType(_ roleID: String, in project: Project) {
        setAgentTypeFilter(roleID, in: project)
        openProject(project, section: .agents)
    }
}
