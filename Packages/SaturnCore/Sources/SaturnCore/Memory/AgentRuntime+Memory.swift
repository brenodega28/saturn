import Foundation

extension AgentRuntime {
    public func memory(for agent: Agent) -> AgentMemory? {
        guard let project = try? database.project(id: agent.projectId) else { return nil }
        return AgentMemory(repository: project.filesRoot, agentName: agent.name)
    }

    func memoryPromptSection(for agent: Agent, repository: URL) -> String? {
        guard agent.isPinned else { return nil }
        return AgentMemory(repository: repository, agentName: agent.name).promptSection()
    }

    func addingMemoryAccess(to setup: TurnSetup, for agent: Agent, repository: URL?) throws -> TurnSetup {
        guard agent.isPinned, let id = agent.id, memoryUpdateAgents.contains(id), let repository else { return setup }
        let memory = AgentMemory(repository: repository, agentName: agent.name)
        let directory = try memory.prepareDirectory()
        let file = "/" + realPath(of: directory) + "/" + memory.url.lastPathComponent
        var updated = setup
        updated.additionalDirectories.append(directory)
        if !setup.readOnly {
            updated.extraAllowedTools += ["Write(\(file))", "Edit(\(file))"]
        }
        return updated
    }
}
