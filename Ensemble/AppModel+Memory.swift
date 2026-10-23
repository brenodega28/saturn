import EnsembleCore
import Foundation

extension AppModel {
    func startMemoryUpdates() {
        guard driver.memoryUpdater == nil else { return }
        let updater = PinnedMemoryUpdater(runtime: agents)
        driver.memoryUpdater = updater
        updater.observe(engine)
    }

    func memory(for session: AgentSession) -> AgentMemory? {
        agents.memory(for: session.agent)
    }

    func isUpdatingMemory(_ session: AgentSession) -> Bool {
        driver.memoryUpdater?.updatingAgentIDs.contains(session.id) ?? false
    }

    func saveMemory(_ text: String, for session: AgentSession) {
        guard let memory = memory(for: session) else { return }
        do {
            try memory.write(text)
        } catch {
            alert = AppAlert(title: "Couldn’t save \(session.agent.name)’s memory", message: error.localizedDescription)
        }
    }

    func clearMemory(for session: AgentSession) {
        guard let memory = memory(for: session) else { return }
        do {
            try memory.clear()
        } catch {
            alert = AppAlert(title: "Couldn’t clear \(session.agent.name)’s memory", message: error.localizedDescription)
        }
    }

    func forgetMemoryNote(at index: Int, for session: AgentSession) {
        guard let memory = memory(for: session) else { return }
        do {
            try memory.forgetNote(at: index)
        } catch {
            alert = AppAlert(title: "Couldn’t forget that note", message: error.localizedDescription)
        }
    }
}
