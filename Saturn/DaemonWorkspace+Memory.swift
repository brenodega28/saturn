import SaturnCore
import Foundation

extension DaemonWorkspace {
    func memory(for session: LiveAgentSession) -> AgentMemory? {
        guard let project = project(withID: session.agent.projectId) else { return nil }
        return AgentMemory(repository: project.filesRoot, agentName: session.agent.name)
    }

    func isUpdatingMemory(_ session: LiveAgentSession) -> Bool {
        session.isUpdatingMemory
    }

    func saveMemory(_ text: String, for session: LiveAgentSession) {
        guard let memory = memory(for: session) else { return }
        do {
            try memory.write(text)
        } catch {
            alert = AppAlert(title: "Couldn’t save \(displayName(of: session.agent))’s memory", message: error.localizedDescription)
        }
    }

    func clearMemory(for session: LiveAgentSession) {
        guard let memory = memory(for: session) else { return }
        do {
            try memory.clear()
        } catch {
            alert = AppAlert(title: "Couldn’t clear \(displayName(of: session.agent))’s memory", message: error.localizedDescription)
        }
    }

    func forgetMemoryNote(at index: Int, for session: LiveAgentSession) {
        guard let memory = memory(for: session) else { return }
        do {
            try memory.forgetNote(at: index)
        } catch {
            alert = AppAlert(title: "Couldn’t forget that note", message: error.localizedDescription)
        }
    }
}
